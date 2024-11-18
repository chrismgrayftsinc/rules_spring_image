load("@aspect_bazel_lib//lib:tar.bzl", "tar")
load("@rules_oci//oci:defs.bzl", "oci_image", "oci_image_rule")

def _depaggregator_rule_impl(ctx):
    # magical incantation for getting upstream transitive closure of java deps
    merged = java_common.merge([dep[java_common.provider] for dep in ctx.attr.deps])

    jars = []
    excludes = {}

    for exclusion_info in ctx.attr.deps_exclude:
        for compile_jar in exclusion_info[JavaInfo].full_compile_jars.to_list():
            excludes[compile_jar.path] = True

    for dep in merged.transitive_runtime_jars.to_list():
        if excludes.get(dep.path, None) == None:
            jars.append(dep)
        else:
            pass

    return [DefaultInfo(files = depset(jars))]

_depaggregator_rule = rule(
    implementation = _depaggregator_rule_impl,
    attrs = {
        "depaggregator_rule": attr.label(),
        "deps": attr.label_list(providers = [java_common.provider]),
        "deps_exclude": attr.label_list(providers = [java_common.provider], allow_empty = True),
    },
)

def _dependencies_copier_rule_impl(ctx):
    outs = []
    for dep in ctx.attr.deps:
        for file in dep.files.to_list():
            path = file.path
            if path.find("spring-boot-loader") >= 0 or path.find("spring_boot_loader") >= 0:
                continue
            else:
                if path.find("external") >= 0 and path.find("maven~", path.find("external")) >= 0:
                    libdestdir = path[path.find("/"):]
                elif path.find("external") >= 0 and path.find("public", path.find("external")) >= 0:
                    libdestdir = path[path.find("public") + len("public"):]
                else:
                    # Probably not a maven dependency.  More likely part of the application
                    continue
                out_path = "BOOT-INF/lib/" + libdestdir
                out = ctx.actions.declare_file(out_path)
                outs += [out]
                ctx.actions.run_shell(
                    outputs = [out],
                    inputs = depset([file]),
                    arguments = [path, out.path],
                    command = "cp $1 $2",
                )
    return [
        DefaultInfo(
            files = depset(outs),
            runfiles = ctx.runfiles(files = outs),
        ),
    ]

_dependencies_copier_rule = rule(
    implementation = _dependencies_copier_rule_impl,
    attrs = {
        "deps": attr.label_list(),
    },
)

def tar_jar(ctx, file, path, out):
    java_runtime = ctx.attr._jdk[java_common.JavaRuntimeInfo]
    jar_path = "%s/bin/jar" % java_runtime.java_home

    file_list_path = "loader_paths"
    file_list = ctx.actions.declare_file(file_list_path)

    ctx.actions.run_shell(
        inputs = ctx.files._jdk + [file],
        outputs = [file_list],
        command = "{jar} tf {path} | grep -v '/$' | sort | uniq > {file_list_path}".format(jar = jar_path, path = path, file_list_path = file_list.path),
    )
    ctx.actions.run_shell(
        inputs = ctx.files._jdk + [file, file_list],
        outputs = [out],
        command = "{jar} xf {path} && cat {file_list_path} | tar cf {out} -T -".format(jar = jar_path, path = path, out = out.path, file_list_path = file_list.path),
    )

def _loader_copier_rule_impl(ctx):
    outs = []
    for dep in ctx.attr.deps:
        for file in dep.files.to_list():
            path = file.path
            if path.find("spring-boot-loader") >= 0 or path.find("spring_boot_loader") >= 0:
                out = ctx.actions.declare_file("loader-output.tar")
                outs += [out]
                tar_jar(ctx, file, path, out)

    return [
        DefaultInfo(
            files = depset(outs),
            runfiles = ctx.runfiles(files = outs),
        ),
    ]

_loader_copier_rule = rule(
    implementation = _loader_copier_rule_impl,
    attrs = {
        "deps": attr.label_list(),
        "_jdk": attr.label(
            default = Label("@bazel_tools//tools/jdk:current_java_runtime"),
            providers = [java_common.JavaRuntimeInfo],
        ),
    },
)

def tar_jars(ctx, files, out):
    java_runtime = ctx.attr._jdk[java_common.JavaRuntimeInfo]
    jar_path = "%s/bin/jar" % java_runtime.java_home
    paths = [f.path for f in files]
    spring_components_file_path = "spring.components"
    spring_components_file = ctx.actions.declare_file(spring_components_file_path)
    ctx.actions.run_shell(
        inputs = ctx.files._jdk + files,
        outputs = [spring_components_file],
        command = "touch {file}; for i in {all_paths}; do {jar} xf $i && if [ -s META-INF/spring.components ]; then cat META-INF/spring.components >> {file}; fi; done".format(file = spring_components_file.path, jar = jar_path, all_paths = " ".join(paths)),
    )

    all_paths_file_path = "application_paths"
    all_paths_file = ctx.actions.declare_file(all_paths_file_path)
    ctx.actions.run_shell(
        inputs = ctx.files._jdk + files,
        outputs = [all_paths_file],
        command = "for i in {all_paths}; do {jar} tf $i | grep -v '/$' | grep -v spring.components | grep -v MANIFEST.MF >> {out}.tmp; done; sort {out}.tmp | uniq > {out}".format(out = all_paths_file.path, all_paths = " ".join(paths), jar = jar_path),
    )

    ctx.actions.run_shell(
        inputs = ctx.files._jdk + files + [spring_components_file, all_paths_file],
        outputs = [out],
        # Create an empty tarball, then extract all the jars and append the contents into it.
        # TODO: get rid of the hardcoded bazel-out path in the first transform.
        command = 'tar cf {out} -T /dev/null && if [ -s {scf} ]; then tar rhf {out} --transform "s,bazel-out/.*/bin/,BOOT-INF/classes/META-INF/," {scf}; fi && for i in {all_paths}; do {jar} xf $i; done && cat {all_paths_file} | tar rf {out} --transform "s,^,BOOT-INF/classes/," -T -'.format(out = out.path, all_paths = " ".join(paths), jar = jar_path, scf = spring_components_file.path, all_paths_file = all_paths_file.path),
    )

def _application_copier_rule_impl(ctx):
    outs = []
    first = True
    jars = []
    for dep in ctx.attr.deps:
        for file in dep.files.to_list():
            path = file.path
            if path.find("spring-boot-loader") >= 0 or path.find("spring_boot_loader") >= 0:
                continue
            elif path.find("external") >= 0 and path.find("maven~", path.find("external")) >= 0:
                continue
            elif path.find("external") >= 0 and path.find("public", path.find("external")) >= 0:
                continue
            else:
                # Probably not a maven dependency.  More likely part of the application
                if first:
                    out = ctx.actions.declare_file("application-output.tar")
                    outs += [out]
                jars.append(file)
                first = False
    tar_jars(ctx, jars, out)
    return [
        DefaultInfo(
            files = depset(outs),
            runfiles = ctx.runfiles(files = outs),
        ),
    ]

_application_copier_rule = rule(
    implementation = _application_copier_rule_impl,
    attrs = {
        "deps": attr.label_list(),
        "_jdk": attr.label(
            default = Label("@bazel_tools//tools/jdk:current_java_runtime"),
            providers = [java_common.JavaRuntimeInfo],
        ),
    },
)

def _gen_layers_idx_rule_impl(ctx):
    outs = []
    maven_dependencies_found = False
    loader_found = False
    application_found = False
    for dep in ctx.attr.deps:
        for file in dep.files.to_list():
            path = file.path
            if path.find("spring-boot-loader") >= 0 or path.find("spring_boot_loader") >= 0:
                loader_found = True
                continue
            elif path.find("external") >= 0 and path.find("maven~", path.find("external")) >= 0:
                maven_dependencies_found = True
                continue
            elif path.find("external") >= 0 and path.find("public", path.find("external")) >= 0:
                continue
            else:
                application_found = True

    out = ctx.actions.declare_file("BOOT-INF/layers.idx")
    content = ""
    if maven_dependencies_found:
        content += """- "dependencies":
  - "BOOT-INF/lib/"
"""
    if loader_found:
        content += """- "spring-boot-loader":
  - "org/"
"""
    if application_found:
        content += """- "application":
  - "BOOT-INF/classes/"
  - "BOOT-INF/classpath.idx"
  - "BOOT-INF/layers.idx"
  - "META-INF/"
"""
    ctx.actions.write(out, content)
    outs = [out]
    return [
        DefaultInfo(
            files = depset(outs),
            runfiles = ctx.runfiles(files = outs),
        ),
    ]

_gen_layers_idx_rule = rule(
    implementation = _gen_layers_idx_rule_impl,
    attrs = {
        "deps": attr.label_list(),
    },
)

def _gen_manifest_rule_impl(ctx):
    java_runtime = ctx.attr._jdk[java_common.JavaRuntimeInfo]
    java_home = java_runtime.java_home
    out = ctx.actions.declare_file(ctx.attr.out)
    mnemonic = "WriteManifest"

    write_manifest_string = """
#!/bin/bash
#
# Copyright (c) 2017-2021, salesforce.com, inc.
# All rights reserved.
# Licensed under the BSD 3-Clause license.
# For full license text, see LICENSE.txt file in the repo root at https://github.com/salesforce/rules_spring  or https://opensource.org/licenses/BSD-3-Clause
#

set -e

mainclass={{mainclass}}
springbootlauncherclass={{springbootlauncherclass}}
manifestfile={{manifestfile}}
javabase={{javabase}}
found_spring_jar=0
# Looking for the springboot jar injected by springboot.bzl and extracting the version

for var in "$@"
do
    # determine the version of spring boot
    # this little area of the rule has had problems in the past; reconsider whether doing
    # this is worth it; and certainly carefully review prior issues here before making changes
    #   Issues: #130, #119, #111
    $javabase/bin/jar xf $var META-INF/MANIFEST.MF || continue
    spring_version=$(grep 'Implementation-Version' META-INF/MANIFEST.MF | cut -d : -f2 | tr -d '[:space:]')
    rm -rf META-INF

    # we do want to validate that the deps include spring boot, and this is a
    # convenient place to do it, but it is a little misplaced as we are
    # generating the manifest in this script
    found_spring_jar=1
    break
done

if test $found_spring_jar -ne 1 ; then
    echo "ERROR: //springboot/write_manifest.sh could not find the spring-boot jar"
    exit 1
fi

#get the java -version details
# todo this isn't the best value to use. it is the version that will be used by the jar tool
# to package the boot jar but not for compiling the code (java_toolchain)
java_string=$($javabase/bin/java -version 2>&1)

#get the first line of the version details and get the version
java_version=$(echo "$java_string" | head -n1 | cut -d ' ' -f 3 | rev | cut -c2- | rev | cut -c2- )

mkdir -p $(dirname $manifestfile)
echo "Manifest-Version: 1.0" > $manifestfile
echo "Created-By: Bazel" >> $manifestfile
echo "Built-By: Bazel" >> $manifestfile
echo "Main-Class: $springbootlauncherclass" >> $manifestfile
echo "Spring-Boot-Classes: BOOT-INF/classes/" >> $manifestfile
echo "Spring-Boot-Lib: BOOT-INF/lib/" >> $manifestfile
echo "Spring-Boot-Version: $spring_version" >> $manifestfile
echo "Build-Jdk: $java_version" >> $manifestfile
echo "Start-Class: $mainclass" >> $manifestfile
"""

    write_manifest_sh = ctx.actions.declare_file("write_manifest.sh")
    write_manifest_tpl_sh = ctx.actions.declare_file("write_manifest.tpl.sh")
    ctx.actions.write(
        output = write_manifest_tpl_sh,
        content = write_manifest_string,
    )

    ctx.actions.expand_template(
        output = write_manifest_sh,
        template = write_manifest_tpl_sh,
        is_executable = True,
        substitutions = {
            "{{mainclass}}": ctx.attr.boot_app_class,
            "{{springbootlauncherclass}}": "org.springframework.boot.loader.JarLauncher",
            "{{manifestfile}}": out.path,
            "{{javabase}}": java_home,
        },
    )

    ctx.actions.run(
        executable = write_manifest_sh,
        outputs = [out],
        inputs = [
            dep
            for src in ctx.attr.srcs
            for dep in src.files.to_list()
        ],
        arguments = [
            dep.path
            for src in ctx.attr.srcs
            for dep in src.files.to_list()
            if dep.path.find("spring-boot") >= 0 or dep.path.find("spring_boot") >= 0
        ],
        tools = [java_runtime.files],
    )
    return [
        DefaultInfo(
            files = depset([out]),
            runfiles = ctx.runfiles(files = [out]),
        ),
    ]

_gen_manifest_rule = rule(
    implementation = _gen_manifest_rule_impl,
    attrs = {
        "srcs": attr.label_list(),
        "out": attr.string(),
        "_jdk": attr.label(
            default = Label("@bazel_tools//tools/jdk:current_java_runtime"),
            providers = [java_common.JavaRuntimeInfo],
        ),
        "boot_app_class": attr.string(),
    },
)

def spring_image(
        name,
        java_library,
        boot_app_class,
        base,
        ports,
        cmd = None,
        entrypoint = None,
        extra_layers = [],
        deps = None,
        deps_exclude = None,
        tags = None):
    dep_aggregator_rule = "_deps"
    genmanifest_rule = "_genmanifest"
    gen_layers_idx_rule = "_gen_layers_idx"
    gen_dependencies_rule = "_gen_dependencies"
    gen_dependencies_layer_rule = "_gen_dependencies_layer"
    gen_loader_rule = "_gen_loader"
    gen_loader_layer_rule = "_gen_loader_layer"
    gen_application_rule = "_gen_application"
    gen_application_layer_rule = "_gen_application_layer"

    java_deps = [java_library]
    if deps != None:
        java_deps = [java_library] + deps

    _depaggregator_rule(
        name = dep_aggregator_rule,
        deps = java_deps,
        deps_exclude = deps_exclude,
        tags = tags,
    )

    genmanifest_out = "META-INF/MANIFEST.MF"
    _gen_manifest_rule(
        name = genmanifest_rule,
        srcs = [":" + dep_aggregator_rule],
        out = genmanifest_out,
        boot_app_class = boot_app_class,
    )

    # Create layers and write layers.idx
    _dependencies_copier_rule(
        name = gen_dependencies_rule,
        deps = [":" + dep_aggregator_rule],
    )

    tar(
        name = "dependencies",
        srcs = [":" + gen_dependencies_rule],
    )

    _loader_copier_rule(
        name = gen_loader_rule,
        deps = [":" + dep_aggregator_rule],
    )

    _application_copier_rule(
        name = gen_application_rule,
        deps = [":" + dep_aggregator_rule],
    )

    _gen_layers_idx_rule(
        name = gen_layers_idx_rule,
        deps = [":" + dep_aggregator_rule],
    )

    tar(
        name = "layers_index",
        srcs = [
            ":" + gen_layers_idx_rule,
        ],
    )

    tar(
        name = "manifest",
        srcs = [
            ":" + genmanifest_rule,
        ],
    )

    oci_image(
        name = name + "-image",
        cmd = cmd,
        entrypoint = entrypoint,
        tars = [
            ":dependencies",
            ":layers_index",
            ":" + gen_loader_rule,
            ":manifest",
            ":" + gen_application_rule,
        ] + extra_layers,
        base = base,
    )

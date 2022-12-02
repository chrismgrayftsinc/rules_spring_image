load("@bazel_tools//tools/build_defs/repo:utils.bzl", "maybe")
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load("@io_bazel_rules_docker//container:container.bzl", "container_image", "container_layer", _container = "container")

def rules_spring_image_deps():
    maybe(
        http_archive,
        name = "com_github_rules_spring",
        sha256 = "4afceddd222bfd596f09591fd41f0800e57dd2d49e3fa0bda67f1b43149e8f3e",
        url = "https://github.com/salesforce/rules_spring/releases/download/2.1.3/rules-spring-2.1.3.zip",
    )
    maybe(
        http_archive,
        name = "com_github_io_bazel_rules_docker",
        sha256 = "59d5b42ac315e7eadffa944e86e90c2990110a1c8075f1cd145f487e999d22b3",
        strip_prefix = "rules_docker-0.17.0",
        urls = ["https://github.com/bazelbuild/rules_docker/releases/download/v0.17.0/rules_docker-v0.17.0.tar.gz"],
    )

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
                if path.find("external") >= 0 and path.find("maven2", path.find("external")) >= 0:
                    libdestdir = path[path.find("maven2") + len("maven2"):]
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
    ctx.actions.run_shell(
        inputs = ctx.files._jdk + [file],
        outputs = [out],
        command = "%s xf %s && %s tf %s | tar cf %s -T -" % (jar_path, path, jar_path, path, out.path),
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
    out_temp = ctx.actions.declare_file("application-output-temp.tar")
    ctx.actions.run_shell(
        inputs = ctx.files._jdk + files,
        outputs = [out_temp],
        # Create an empty tarball, then extract all the jars and append the contents into it.
        command = 'tar cf %s -T /dev/null && for i in %s; do %s xf ${i} && %s tf ${i} | tar rf %s --transform "s,^,BOOT-INF/classes/," -T -; done' % (out.path, " ".join(paths), jar_path, jar_path, out.path),
    )
    ctx.actions.run_shell(
        inputs = ctx.files._jdk + files + [out_temp],
        outputs = [out],
        command = "mkdir -p BOOT-INF/classes/META-INF; for i in %s; do %s xf ${i} && cat META-INF/spring.components >> BOOT-INF/classes/META-INF/spring.components; done ; if [ -s BOOT-INF/classes/META-INF/spring.components ]; then tar rf %s BOOT-INF/classes/META-INF/spring.components ; fi && mv %s %s" % (" ".join(paths), jar_path, out_temp.path, out_temp.path, out.path),
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
            elif path.find("external") >= 0 and path.find("maven2", path.find("external")) >= 0:
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
            elif path.find("external") >= 0 and path.find("maven2", path.find("external")) >= 0:
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

def _spring_image_rule_impl(ctx):
    return _container.image.implementation(
        ctx = ctx,
        name = ctx.attr.name,
        cmd = ctx.attr.cmd,
        layers = [ctx.attr.dependencies_layer, ctx.attr.loader_layer, ctx.attr.application_layer] + ctx.attr.extra_layers,
    )

_spring_image_rule = rule(
    implementation = _spring_image_rule_impl,
    executable = True,
    outputs = _container.image.outputs,
    attrs = dict(
        _container.image.attrs,
        base = attr.label(),
        ports = attr.string_list(),
        app_compile_rule = attr.label(),
        extra_layers = attr.label_list(),
        java_library = attr.string(),
        boot_app_class = attr.string(),
        deps = attr.label_list(),
        deps_exclude = attr.label_list(),
        application_layer = attr.label(),
        loader_layer = attr.label(),
        dependencies_layer = attr.label(),
    ),
    toolchains = ["@io_bazel_rules_docker//toolchains/docker:toolchain_type"],
)

def spring_image(
        name,
        java_library,
        boot_app_class,
        cmd,
        base,
        ports,
        extra_layers = None,
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
    native.genrule(
        name = genmanifest_rule,
        srcs = [":" + dep_aggregator_rule],
        cmd = "$(location @com_github_rules_spring//springboot:write_manifest.sh) " + boot_app_class + " $@ $(JAVABASE) $(SRCS)",
        tools = ["@com_github_rules_spring//springboot:write_manifest.sh"],
        outs = [genmanifest_out],
        tags = tags,
        toolchains = ["@bazel_tools//tools/jdk:current_host_java_runtime"],
    )

    # Create layers and write layers.idx
    _dependencies_copier_rule(
        name = gen_dependencies_rule,
        deps = [":" + dep_aggregator_rule],
    )

    container_layer(
        name = "dependencies",
        data_path = "BOOT-INF/lib/",
        files = [":" + gen_dependencies_rule],
    )

    _loader_copier_rule(
        name = gen_loader_rule,
        deps = [":" + dep_aggregator_rule],
    )

    container_layer(
        name = "spring-boot-loader",
        tars = [":" + gen_loader_rule],
    )

    _application_copier_rule(
        name = gen_application_rule,
        deps = [":" + dep_aggregator_rule],
    )

    _gen_layers_idx_rule(
        name = gen_layers_idx_rule,
        deps = [":" + dep_aggregator_rule],
    )

    container_layer(
        name = "application",
        tars = [":" + gen_application_rule],
        data_path = ".",
        files = [":" + genmanifest_rule, ":" + gen_layers_idx_rule],
    )
    _spring_image_rule(
        name = name,
        app_compile_rule = java_library,
        boot_app_class = boot_app_class,
        cmd = cmd,
        base = base,
        ports = ports,
        extra_layers = extra_layers,
        application_layer = ":application",
        loader_layer = ":spring-boot-loader",
        dependencies_layer = ":dependencies",
    )

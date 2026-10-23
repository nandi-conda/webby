"""webby's fast checks. Each one gets only the files it reads, so a change elsewhere in the repo is a cache hit.

Also `runtime`, the Ladybird engine build (not a check: half an hour or more cold). Not here: the Android native build
(android-native-build.yml).
"""

from typing import Annotated

import dagger
from dagger import DefaultPath, Doc, Ignore, check, dag, function, object_type

PIXI_IMAGE = "ghcr.io/prefix-dev/pixi:0.82.0"  # new enough for pixi.toml's platform tables
DART_IMAGE = "dart:3.9"  # sync-server/Dockerfile's
PYTHON_IMAGE = "python:3.13-slim"
NODE_IMAGE = "node:22-bookworm"
UV_IMAGE = "ghcr.io/astral-sh/uv:0.13.5"  # pywrangler wants uv >= 0.13.4
RUNTIME_IMAGE = "ubuntu:22.04"  # glibc 2.35, as scripts/portable_build.sh: the runtime installs on ordinary distros
LADYBIRD_REPO = "https://github.com/LadybirdBrowser/ladybird.git"


async def run(ctr: dagger.Container) -> None:
    """Evaluates ctr; on a failed command, the error carries the command and its output."""
    try:
        await ctr.sync()
    except dagger.ExecError as e:
        raise RuntimeError(f"`{' '.join(e.command)}` exited {e.exit_code}\n{e.stdout[-3000:]}\n{e.stderr[-6000:]}") from None


@object_type
class WebbyCi:
    source: Annotated[
        dagger.Directory,
        DefaultPath("/"),
        Ignore([".git", ".pixi", "third_party", "nim/webby", "**/.venv", "**/node_modules", "**/__pycache__"]),
        Doc("The webby checkout"),
    ]

    @function
    def pixi_env(self) -> dagger.Container:
        """The pixi default environment from pixi.toml/pixi.lock: Nim, clang, GTK 3 and webby-ladybird.

        Only pixi.toml and pixi.lock go in before the install, so it reruns only when they change.
        """
        # The env's package downloads are kept between runs, so even a changed lock fetches only what's new.
        return (
            dag.container()
            .from_(PIXI_IMAGE)
            .with_mounted_cache("/root/.cache/rattler", dag.cache_volume("webby-rattler"))
            .with_workdir("/src")
            .with_file("/src/pixi.toml", self.source.file("pixi.toml"))
            .with_file("/src/pixi.lock", self.source.file("pixi.lock"))
            # Not --locked: pixi.toml may be ahead of the lock (a version bump pushed without relocking), as
            # `pixi run` on a laptop allows too.
            .with_exec(["pixi", "install"])
        )

    def _nim_sources(self) -> dagger.Directory:
        return self.source.filter(
            include=["nim/**", "framework/**", "icons/**", "scripts/pixi_nim.sh", "conda/webby/webby-fonts.conf"],
            exclude=["nim/android-kit/**", "framework/android/**"],
        )

    @function
    @check
    async def nim_desktop(self) -> None:
        """Builds the Nim front end (nim/) the way `pixi run webby` does, without starting it."""
        await run(
            self.pixi_env()
            .with_directory("/src", self._nim_sources())
            .with_env_variable("WEBBY_BUILD_ONLY", "1")
            .with_exec(["pixi", "run", "--frozen", "webby"])
        )

    @function
    @check
    async def nimkit_demo(self) -> None:
        """Builds the nimkit demo (framework/) for GTK and for the web."""
        await run(
            self.pixi_env()
            .with_directory("/src", self._nim_sources())
            .with_exec(["pixi", "run", "--frozen", "nim", "c", "-d:release", "--hints:off", "--cc:clang",
                        "--path:framework/src", "-o:/tmp/nimkit-demo", "framework/demo/demo.nim"])
            .with_exec(["pixi", "run", "--frozen", "framework/web/build.sh", "framework/demo/demo.nim", "/tmp/web"])
        )

    def _sync_server_dir(self) -> dagger.Directory:
        return self.source.directory("sync-server").filter(exclude=[".dart_tool/**", "build/**"])

    @function
    @check
    async def sync_server_test(self) -> None:
        """`dart test` for the self-hosted sync server (sync-server/)."""
        await run(
            dag.container()
            .from_(DART_IMAGE)
            .with_mounted_cache("/root/.pub-cache", dag.cache_volume("webby-pub-cache"))
            .with_workdir("/src")
            .with_file("/src/pubspec.yaml", self._sync_server_dir().file("pubspec.yaml"))
            .with_exec(["dart", "pub", "get"])
            .with_directory("/src", self._sync_server_dir())
            .with_exec(["dart", "test"])
        )

    @function
    def sync_server(self) -> dagger.Service:
        """The sync server built from sync-server/Dockerfile, on :8080."""
        return (
            self._sync_server_dir()
            .docker_build()
            .with_exposed_port(8080)
            .as_service(use_entrypoint=True)
        )

    @function
    def sync_worker(self) -> dagger.Service:
        """The Cloudflare sync Worker (sync-worker/) under `pywrangler dev` with a local R2, on :8787."""
        return (
            dag.container()
            .from_(NODE_IMAGE)
            .with_file("/usr/local/bin/uv", dag.container().from_(UV_IMAGE).file("/uv"))
            .with_mounted_cache("/root/.cache/uv", dag.cache_volume("webby-uv"))
            .with_mounted_cache("/root/.npm", dag.cache_volume("webby-npm"))
            .with_env_variable("WRANGLER_SEND_METRICS", "false")
            .with_env_variable("CI", "1")
            .with_directory("/src", self.source.directory("sync-worker"))
            .with_workdir("/src")
            .with_exec(["uv", "sync"])
            .with_exposed_port(8787)
            .as_service(args=["uv", "run", "pywrangler", "dev", "--ip", "0.0.0.0", "--port", "8787"])
        )

    async def _roundtrip(self, server: dagger.Service, url: str) -> None:
        await run(
            dag.container()
            .from_(PYTHON_IMAGE)
            .with_service_binding("sync", server)
            .with_file("/roundtrip.py", self.source.file("sync-worker/test/roundtrip.py"))
            .with_exec(["python3", "/roundtrip.py", url])
        )

    @function
    @check
    async def sync_server_roundtrip(self) -> None:
        """sync-worker/test/roundtrip.py against the Dart sync server: both servers must speak the same API."""
        await self._roundtrip(self.sync_server(), "http://sync:8080")

    @function
    @check
    async def sync_worker_roundtrip(self) -> None:
        """sync-worker/test/roundtrip.py against the Worker under `pywrangler dev`, as the sync-worker README does."""
        await self._roundtrip(self.sync_worker(), "http://sync:8787")

    @function
    def runtime_toolchain(self) -> dagger.Container:
        """Ubuntu 22.04 with what Ladybird needs: clang 21, libstdc++ 14, CMake 3.30+, Rust (scripts/portable_build.sh's)."""
        return (
            dag.container()
            .from_(RUNTIME_IMAGE)
            .with_env_variable("DEBIAN_FRONTEND", "noninteractive")
            .with_exec(["sh", "-ec", """
                apt-get update -qq
                apt-get install -y -qq ca-certificates curl wget gnupg software-properties-common lsb-release git \\
                  python3 python3-venv python3-pip ccache ninja-build autoconf autoconf-archive automake build-essential \\
                  libtool nasm pkg-config zip unzip tar libgl1-mesa-dev libdrm-dev libpulse-dev libncurses-dev \\
                  glslang-tools xz-utils zstd file bison flex gperf patchelf
                wget -qO /usr/share/keyrings/llvm-snapshot.gpg.key https://apt.llvm.org/llvm-snapshot.gpg.key
                echo "deb [signed-by=/usr/share/keyrings/llvm-snapshot.gpg.key] https://apt.llvm.org/jammy/ llvm-toolchain-jammy-21 main" \\
                  > /etc/apt/sources.list.d/llvm.list
                add-apt-repository -y ppa:ubuntu-toolchain-r/test
                apt-get update -qq
                apt-get install -y -qq clang-21 lld-21 llvm-21 libstdc++-14-dev g++-14
                python3 -m venv /opt/venv && /opt/venv/bin/pip install -q 'cmake>=3.30,<4'
                curl -sSf https://sh.rustup.rs | sh -s -- -y -q --no-modify-path --default-toolchain 1.98.0
            """])
            .with_env_variable("PATH", "/usr/lib/llvm-21/bin:/opt/venv/bin:/root/.cargo/bin:${PATH}", expand=True)
        )

    @function
    async def runtime(
        self,
        poke: Annotated[str, Doc("If set, a one-line patch to a LibWeb file on top of patches/, to time a small change")] = "",
    ) -> dagger.File:
        """The Ladybird runtime tarball (webby-prebuilt-linux-x64.tar.zst): scripts/build_ladybird.sh, then pack_prebuilt.sh.

        Cache volumes keep ccache, vcpkg's binary cache, cargo's downloads and the build tree (per Ladybird commit, so
        ninja never sees an older tree's objects) between runs on the same engine.
        """
        commit = (await self.source.file("LADYBIRD_COMMIT").contents()).strip()
        webby = self.source.filter(
            include=["LADYBIRD_COMMIT", "patches/**", "native/**", "scripts/build_ladybird.sh", "scripts/pack_prebuilt.sh"]
        )
        ctr = (
            self.runtime_toolchain()
            .with_directory("/ladybird", dag.git(LADYBIRD_REPO).commit(commit).tree())
            .with_directory("/webby", webby)
        )
        if poke:
            # A real patch, applied after ours, so it goes through the same reset-and-apply as a patches/ change.
            ctr = ctr.with_env_variable("POKE", poke).with_exec(["sh", "-ec", """
                cd /ladybird
                f=Libraries/LibWeb/DOM/Comment.cpp
                cp $f /tmp/orig
                echo "// poke: $POKE" >> $f
                diff -u --label a/$f --label b/$f /tmp/orig $f > /webby/patches/9999-poke.patch || true
                cp /tmp/orig $f
            """])
        ctr = (
            ctr.with_mounted_cache("/ladybird/Build", dag.cache_volume(f"webby-ladybird-build-{commit[:12]}"))
            .with_mounted_cache("/ccache", dag.cache_volume("webby-ladybird-ccache"))
            .with_mounted_cache("/vcpkg-cache", dag.cache_volume("webby-ladybird-vcpkg"))
            .with_mounted_cache("/root/.cargo/registry", dag.cache_volume("webby-cargo-registry"))
            .with_env_variable("LADYBIRD_DIR", "/ladybird")
            .with_env_variable("CC", "clang")
            .with_env_variable("CXX", "clang++")
            .with_env_variable("LINKER", "lld")
            .with_env_variable("CCACHE_DIR", "/ccache")
            .with_env_variable("CCACHE_MAXSIZE", "30G")
            .with_env_variable("VCPKG_DEFAULT_BINARY_CACHE", "/vcpkg-cache")
            # The build tree is a cache volume, so the tarball has to be packed in the same step to leave it.
            .with_exec(["bash", "-ec", """
                ccache -z >/dev/null
                start=$(date +%s)
                /webby/scripts/build_ladybird.sh
                echo "build_ladybird.sh took $(( $(date +%s) - start ))s on $(nproc) CPUs"
                ccache -s
                /webby/scripts/pack_prebuilt.sh /ladybird/Build/release /out
            """])
        )
        await run(ctr)
        return ctr.file("/out/webby-prebuilt-linux-x64.tar.zst")

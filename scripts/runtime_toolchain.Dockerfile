# The image .github/workflows/runtime-build.yml runs in: Ubuntu 22.04 (glibc 2.35) with scripts/portable_toolchain.sh
# already run, plus gh for publishing, so a build doesn't spend ~90 s installing clang, CMake and Rust first.
# Built and pushed to ghcr.io/nandi-conda/webby-runtime-toolchain by .github/workflows/runtime-toolchain.yml on Depot.
FROM ubuntu:22.04
ENV HOME=/root
COPY scripts/portable_toolchain.sh /tmp/portable_toolchain.sh
RUN bash -c 'set -e; source /tmp/portable_toolchain.sh' \
 && wget -qO /usr/share/keyrings/githubcli.gpg https://cli.github.com/packages/githubcli-archive-keyring.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update -qq && apt-get install -y -qq gh \
 && apt-get clean && rm -rf /var/lib/apt/lists/* /root/.cache /tmp/portable_toolchain.sh
ENV PATH=/build/cargo/bin:/usr/lib/llvm-21/bin:/build/venv/bin:$PATH RUSTUP_HOME=/build/rustup CARGO_HOME=/build/cargo

ARG BASE_CONTAINER=quay.io/jupyter/base-notebook@sha256:1b5f7be5d646dff573b0e8275649d954d07a5432597b3e5fe22654148caeec3f
ARG BASE_IMAGE=base

FROM $BASE_CONTAINER AS base

LABEL maintainer="James Brock <jamesbrock@gmail.com>"

# Extra arguments to `stack build`. Used to build --fast, see Makefile.
ARG STACK_ARGS="--no-library-profiling --no-executable-profiling --no-haddock"
USER root

# The global snapshot package database will be here in the STACK_ROOT.
ENV STACK_ROOT=/opt/stack
RUN mkdir -p $STACK_ROOT
RUN fix-permissions $STACK_ROOT

# Install system dependencies (Core Haskell and IHaskell dependencies only)
RUN apt-get update && apt-get install -yq --no-install-recommends \
        python3-pip \
        git \
        libtinfo-dev \
        libzmq3-dev \
        libffi-dev \
        libgmp-dev \
        gnupg \
        netbase \
        curl \
        pkg-config \
# Stack Debian/Ubuntu manual install dependencies
# https://docs.haskellstack.org/en/stable/install_and_upgrade/#linux-generic
        g++ \
        gcc \
        libc6-dev \
        make \
        xz-utils \
        zlib1g-dev \
# Need less for general maintenance
        less && \
# Clean up apt
    rm -rf /var/lib/apt/lists/*

# Architecture-aware Stack download
ARG STACK_VERSION="3.5.1"
RUN cd /tmp \
    && ARCH=$(uname -m) \
    && if [ "$ARCH" = "aarch64" ]; then \
         STACK_BINDIST="stack-${STACK_VERSION}-linux-aarch64"; \
       else \
         STACK_BINDIST="stack-${STACK_VERSION}-linux-x86_64"; \
       fi \
    && curl -sSL --output ${STACK_BINDIST}.tar.gz https://github.com/commercialhaskell/stack/releases/download/v${STACK_VERSION}/${STACK_BINDIST}.tar.gz \
    && tar zxf ${STACK_BINDIST}.tar.gz \
    && cp ${STACK_BINDIST}/stack /usr/bin/stack \
    && rm -rf ${STACK_BINDIST}.tar.gz ${STACK_BINDIST} \
    && stack --version

# Stack global non-project-specific config stack.config.yaml
# https://docs.haskellstack.org/en/stable/yaml_configuration/#non-project-specific-config
RUN mkdir -p /etc/stack
COPY stack.config.yaml /etc/stack/config.yaml
RUN fix-permissions /etc/stack

# Stack global project stack.yaml
# https://docs.haskellstack.org/en/stable/yaml_configuration/#yaml-configuration
RUN mkdir -p $STACK_ROOT/global-project
COPY global-project.stack.yaml $STACK_ROOT/global-project/stack.yaml
RUN chown --recursive $NB_UID:users $STACK_ROOT/global-project \
    && fix-permissions $STACK_ROOT/global-project

# fix-permissions for /usr/local/share/jupyter so that we can install
# the IHaskell kernel there. Seems like the best place to install it, see
#      jupyter --paths
#      jupyter kernelspec list
RUN mkdir -p /usr/local/share/jupyter \
    && fix-permissions /usr/local/share/jupyter \
    && mkdir -p /usr/local/share/jupyter/kernels \
    && fix-permissions /usr/local/share/jupyter/kernels

# Now make a bin directory for installing the ihaskell executable on
# the PATH. This /opt/bin is referenced by the stack non-project-specific
# config.
RUN mkdir -p /opt/bin \
    && fix-permissions /opt/bin
ENV PATH=${PATH}:/opt/bin

# Specify a git branch for IHaskell (can be branch or tag).
# The resolver for all stack builds will be chosen from
# the IHaskell/stack.yaml in this commit.
# https://github.com/gibiansky/IHaskell/commits/master
# IHaskell 2025-11-06
ARG IHASKELL_COMMIT=70d25a03c5a76730ee454a99c4ea04ae7f539391

# Specify a git branch for hvega
# https://github.com/DougBurke/hvega/commits/main
# hvega 2025-03-12
# hvega-0.12.0.7
# ihaskell-hvega-0.5.0.6
ARG HVEGA_COMMIT=5e18d53b7748dc5e23c6cd6c38dc722f01e2dde6

# Clone IHaskell and install ghc natively
# Everything is chained in one RUN to prevent intermediate layers from bloating the image.
RUN cd /opt \
    && curl -L "https://github.com/gibiansky/IHaskell/tarball/$IHASKELL_COMMIT" | tar xzf - \
    && mv *IHaskell* IHaskell \
    && curl -L "https://github.com/DougBurke/hvega/tarball/$HVEGA_COMMIT" | tar xzf - \
    && mv *hvega* hvega \
    && fix-permissions /opt/IHaskell \
    && fix-permissions $STACK_ROOT \
    && fix-permissions /opt/hvega \
    && stack setup \
    && rm -f /opt/stack/programs/*-linux/ghc*.tar.xz \
    && stack build $STACK_ARGS ihaskell \
    && rm -rf /opt/IHaskell/.stack-work \
    && rm -rf /opt/hvega/.stack-work \
    && find /opt/stack/snapshots -type d -name "build" -exec rm -rf {} + \
    && find /opt/stack/programs -type f \( -name "*_p.a" -o -name "*.p_hi" \) -delete \
    && find /opt/stack -type f \( -name "*.o" -o -name "*.dyn_o" \) -delete \
    && find /opt/IHaskell -type f \( -name "*.o" -o -name "*.dyn_o" \) -delete \
    && fix-permissions /opt/IHaskell \
    && fix-permissions $STACK_ROOT

# Bug workaround for https://github.com/IHaskell/ihaskell-notebook/issues/9
RUN mkdir -p /home/jovyan/.local/share/jupyter/runtime \
    && fix-permissions /home/jovyan/.local \
    && fix-permissions /home/jovyan/.local/share \
    && fix-permissions /home/jovyan/.local/share/jupyter \
    && fix-permissions /home/jovyan/.local/share/jupyter/runtime

# Install system-level ghc using the ghc which was installed by stack
# using the IHaskell resolver.
RUN mkdir -p /opt/ghc && ln -s `stack path --compiler-bin` /opt/ghc/bin \
    && fix-permissions /opt/ghc
ENV PATH=${PATH}:/opt/ghc/bin

# Switch back to jovyan user to install kernel
USER $NB_UID
RUN stack exec ihaskell -- install --stack --prefix=/usr/local

# ============================================================================
# Stage 2: Full (AS full)
# ============================================================================
FROM $BASE_IMAGE AS full
USER root

# Install display system dependencies (Cairo, Pango, Graphviz, Gnuplot, etc.)
RUN apt-get update && apt-get install -yq --no-install-recommends \
        libcairo2-dev \
        libpango1.0-dev \
        libmagic-dev \
        libblas-dev \
        liblapack-dev \
        graphviz \
        gnuplot-nox && \
    rm -rf /var/lib/apt/lists/*

# Install IHaskell.Display libraries and immediately clean up artifacts
# https://github.com/gibiansky/IHaskell/tree/master/ihaskell-display
RUN stack build $STACK_ARGS ihaskell-aeson \
    && stack build $STACK_ARGS ihaskell-blaze \
    && stack build $STACK_ARGS ihaskell-charts \
    && stack build $STACK_ARGS ihaskell-diagrams \
    && stack build $STACK_ARGS ihaskell-gnuplot \
    && stack build $STACK_ARGS ihaskell-graphviz \
    && stack build $STACK_ARGS ihaskell-hatex \
    && stack build $STACK_ARGS ihaskell-juicypixels \
    && stack build $STACK_ARGS ihaskell-plot \
    && stack build $STACK_ARGS ihaskell-widgets \
    && stack build $STACK_ARGS hvega \
    && stack build $STACK_ARGS ihaskell-hvega \
    && rm -rf /opt/IHaskell/.stack-work \
    && rm -rf /opt/hvega/.stack-work \
    && find /opt/stack/snapshots -type d -name "build" -exec rm -rf {} + \
    && find /opt/stack -type f \( -name "*.o" -o -name "*.dyn_o" \) -delete \
    && find /opt/IHaskell -type f \( -name "*.o" -o -name "*.dyn_o" \) -delete \
    && find /opt/hvega -type f \( -name "*.o" -o -name "*.dyn_o" \) -delete \
    && fix-permissions $STACK_ROOT \
    # Fix for https://github.com/IHaskell/ihaskell-notebook/issues/14#issuecomment-636334824
    && fix-permissions /opt/IHaskell \
    && fix-permissions /opt/hvega

# Switch to jovyan user for runtime configuration
USER $NB_UID

RUN conda install --quiet --yes \
# ihaskell-widgets needs ipywidgets
    'ipywidgets=8.1.7' && \
# ihaskell-hvega doesn't need an extension. https://github.com/jupyterlab/jupyter-renderers
#    'jupyterlab-vega3' && \
    conda clean --all -f -y && \
    fix-permissions "${CONDA_DIR}" && \
    fix-permissions "/home/${NB_USER}"

# Example IHaskell notebooks will be collected in this directory.
ARG EXAMPLES_PATH=/home/$NB_USER/ihaskell_examples

# Collect all the IHaskell example notebooks in EXAMPLES_PATH.
RUN mkdir -p $EXAMPLES_PATH \
    && cd $EXAMPLES_PATH \
    && mkdir -p ihaskell \
    && cp --recursive /opt/IHaskell/notebooks/* ihaskell/ \
    && mkdir -p ihaskell-juicypixels \
    && cp /opt/IHaskell/ihaskell-display/ihaskell-juicypixels/*.ipynb ihaskell-juicypixels/ \
    && mkdir -p ihaskell-charts \
    && cp /opt/IHaskell/ihaskell-display/ihaskell-charts/*.ipynb ihaskell-charts/ \
    && mkdir -p ihaskell-diagrams \
    && cp /opt/IHaskell/ihaskell-display/ihaskell-diagrams/*.ipynb ihaskell-diagrams/ \
    && mkdir -p ihaskell-gnuplot \
    && cp /opt/IHaskell/ihaskell-display/ihaskell-gnuplot/*.ipynb ihaskell-gnuplot/ \
    && mkdir -p ihaskell-widgets \
    && cp --recursive /opt/IHaskell/ihaskell-display/ihaskell-widgets/Examples/* ihaskell-widgets/ \
    && mkdir -p ihaskell-hvega \
    && cp /opt/hvega/notebooks/*.ipynb ihaskell-hvega/ \
    && cp /opt/hvega/notebooks/*.tsv ihaskell-hvega/ \
    && mkdir -p ihaskell-plot \
    && cp /opt/IHaskell/ihaskell-display/ihaskell-plot/PlotExample.ipynb ihaskell-plot/ \
    && fix-permissions $EXAMPLES_PATH

FROM    ubuntu:bionic
SHELL   ["/bin/bash", "-c"]
RUN     apt-get update && \
        apt-get install -y software-properties-common && \
		apt-get -y install sudo && \
        apt-add-repository universe && \
        apt-get update && \
        apt-get install -y python3.8 && \
        update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.8 1 && \
        apt-get install -y python-pip && \
        apt-get install -y python3.8-venv && \
        DEBIAN_FRONTEND="noninteractive" apt-get install -y build-essential git libftdi-dev libftdi1 doxygen python3-pip libsdl2-dev curl cmake libusb-1.0-0-dev gtkwave libsndfile1-dev rsync autoconf automake texinfo libtool pkg-config libsdl2-ttf-dev wget unzip sed

#RUN     stat /etc/udev/
#RUN     cp /usr/share/gap8-openocd/openocd/contrib/60-openocd.rules /etc/udev/rules.d
#RUN     udevadm control --reload-rules && sudo udevadm trigger
#RUN     usermod -a -G dialout ubuntu
# GAP-SDK & TOOLCHAIN INSTALLATION
RUN     python3 -m venv /dory_env && \
        source /dory_env/bin/activate && \
        git clone https://github.com/GreenWaves-Technologies/gap8_openocd.git && \
        cd gap8_openocd && \
       ./bootstrap && \
        ./configure --program-prefix=gap8- --prefix=/usr --datarootdir=/usr/share/gap8-openocd && \
        make -j && \
        make -j install
# Install the GAP8 RISC-V toolchain in its own cached Docker layer.
RUN source /dory_env/bin/activate && \
    cd / && \
    git clone --depth 1 \
      https://github.com/GreenWaves-Technologies/gap_riscv_toolchain_ubuntu_18.git && \
    cd /gap_riscv_toolchain_ubuntu_18 && \
    ./install.sh /usr/lib/gap_riscv_toolchain

# Clone the exact GAP SDK revision separately so a network failure does not
# invalidate the expensive toolchain layer.
RUN source /dory_env/bin/activate && \
    cd / && \
    for attempt in 1 2 3 4 5; do \
      rm -rf /gap_sdk && \
      git -c http.version=HTTP/1.1 \
          -c http.lowSpeedLimit=1000 \
          -c http.lowSpeedTime=120 \
          clone --filter=blob:none --no-checkout \
          https://github.com/GreenWaves-Technologies/gap_sdk.git /gap_sdk && \
      cd /gap_sdk && \
      git -c http.version=HTTP/1.1 fetch --depth 1 origin \
          a3dedd5cd8a680a88d2dca2ab7a4ae65cebf4c8d && \
      git checkout --detach FETCH_HEAD && \
      break; \
      echo "GAP SDK clone attempt ${attempt} failed"; \
      cd /; \
      sleep 10; \
    done && \
    test -d /gap_sdk/.git && \
    cd /gap_sdk && \
    python3 -m pip install wheel && \
    python3 -m pip install scons && \
    python3 -m pip install Cython && \
    python3 -m pip install --upgrade pip setuptools wheel && \
    python3 -m pip install setuptools_rust && \
    python3 -m pip install -r requirements.txt
RUN source /dory_env/bin/activate && \
    cd /gap_sdk && \
    source sourceme.sh && \
    make minimal

RUN source /dory_env/bin/activate && \
    cd /gap_sdk && \
    source sourceme.sh && \
    make gvsoc

# PULP-SDK INSTALLATION
RUN set -eux; \
    mkdir -p /pulp-sdk; \
    cd /pulp-sdk; \
    git init; \
    git remote add origin https://github.com/pulp-platform/pulp-sdk.git; \
    for attempt in 1 2 3 4 5; do \
        git -c http.version=HTTP/1.1 fetch --depth 1 origin \
            1f6a59e9b3def1585cd726872ea93b134a46faa2 && break; \
        if [ "$attempt" -eq 5 ]; then exit 1; fi; \
        sleep $((attempt * 5)); \
    done; \
    git checkout --detach FETCH_HEAD

# Pre-fetch the exact xtensor dependencies expected by rules/gvsoc.mk.
RUN set -eux; \
    cd /pulp-sdk; \
    rm -rf ext/xtensor; \
    mkdir -p ext/xtensor/include; \
    clone_tag() { \
        repo="$1"; \
        tag="$2"; \
        destination="$3"; \
        for attempt in 1 2 3 4 5; do \
            git -c http.version=HTTP/1.1 clone \
                --depth 1 \
                --branch "$tag" \
                "$repo" "$destination" && return 0; \
            rm -rf "$destination"; \
            if [ "$attempt" -eq 5 ]; then return 1; fi; \
            sleep $((attempt * 5)); \
        done; \
    }; \
    clone_tag https://github.com/xtensor-stack/xtl.git 0.6.14 /tmp/xtl; \
    clone_tag https://github.com/xtensor-stack/xtensor.git 0.21.5 /tmp/xtensor; \
    clone_tag https://github.com/xtensor-stack/xsimd.git 7.4.7 /tmp/xsimd; \
    mv /tmp/xtl/include/xtl ext/xtensor/include/; \
    mv /tmp/xtensor/include/xtensor ext/xtensor/include/; \
    mv /tmp/xsimd/include/xsimd ext/xtensor/include/; \
    rm -rf /tmp/xtl /tmp/xtensor /tmp/xsimd

RUN source /dory_env/bin/activate && \
    cd /pulp-sdk && \
    source configs/pulp-open-nn.sh && \
    make all

# PULP-NN TOOLCHAIN DOWNLOAD
RUN set -eux; \
    cd /; \
    for attempt in 1 2 3 4 5; do \
        wget \
            --continue \
            --timeout=30 \
            --tries=3 \
            -O riscv-nn-toolchain.zip \
            https://iis-nextcloud.ee.ethz.ch/s/aYESyR5W9FrHgYa/download/riscv-nn-toolchain.zip \
            && break; \
        if [ "$attempt" -eq 5 ]; then exit 1; fi; \
        sleep $((attempt * 5)); \
    done; \
    unzip riscv-nn-toolchain.zip; \
    rm riscv-nn-toolchain.zip
# FINALIZE PYTHON VENV
WORKDIR /gap_sdk/

ENV PIP_DEFAULT_TIMEOUT=300 \
    PIP_RETRIES=10 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN source /dory_env/bin/activate && \
    python3 -m pip install \
        --timeout 300 \
        --retries 10 \
        --upgrade \
        python-dev-tools

RUN source /dory_env/bin/activate && \
    python3 -m pip install \
        --timeout 300 \
        --retries 10 \
        numpy \
        onnx \
        future-fstrings \
        pandas \
        ortools \
        mako \
        pytest \
        Pygments \
        MarkupSafe \
        prettytable

RUN source /dory_env/bin/activate && \
    python3 -m pip uninstall -y torch torchvision && \
    python3 -m pip install \
        --timeout 300 \
        --retries 10 \
        torch==1.6.0 \
        torchvision==0.7.0

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Install prerequisites for PostgreSQL, build toolchain, and BCC/eBPF
RUN apt-get update && apt-get install -y \
    wget \
    gnupg2 \
    lsb-release \
    curl \
    git \
    build-essential \
    clang \
    llvm \
    libbpf-dev \
    linux-headers-generic \
    linux-tools-common \
    linux-tools-generic \
    bpfcc-tools \
    python3-bpfcc \
    python3-pip \
    python3-venv \
    sudo \
    tzdata \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Add official PostgreSQL APT repository for v17
RUN echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list && \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg

# Install PostgreSQL 17 server, client, dev headers, and contrib
RUN apt-get update && apt-get install -y \
    postgresql-17 \
    postgresql-server-dev-17 \
    postgresql-client-17 \
    postgresql-contrib \
    && rm -rf /var/lib/apt/lists/*

# Configure directory and permissions
RUN mkdir -p /var/run/postgresql && chown -R postgres:postgres /var/run/postgresql
RUN mkdir -p /dataset_workspace

WORKDIR /dataset_workspace

# Copy requirements and install Python dependencies
COPY requirements.txt /dataset_workspace/requirements.txt
RUN pip3 install --no-cache-dir --break-system-packages -r /dataset_workspace/requirements.txt

# Copy project files
COPY . /dataset_workspace

# Compile and install pg_telemetry extension
RUN cd /dataset_workspace/pg_telemetry_extension && make clean && make && make install

# Configure postgres user and default data directory
RUN usermod -aG sudo postgres && echo "postgres ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

EXPOSE 5432

ENTRYPOINT ["/bin/bash", "/dataset_workspace/docker/entrypoint.sh"]

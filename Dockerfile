FROM ubuntu:24.04

# Avoid interactive prompts during apt-get
ENV DEBIAN_FRONTEND=noninteractive

# Install prerequisites for adding repositories and building C/eBPF tools
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
    sudo \
    tzdata \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Add PostgreSQL repository for v17
RUN echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list && \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add -

# Install PostgreSQL 17, pgBench, and standard dev headers
RUN apt-get update && apt-get install -y \
    postgresql-17 \
    postgresql-server-dev-17 \
    postgresql-client-17 \
    postgresql-contrib \
    && rm -rf /var/lib/apt/lists/*

# Fix postgres permissions
RUN mkdir -p /var/run/postgresql && chown -R postgres:postgres /var/run/postgresql

# Create working directories for the dataset generator
WORKDIR /dataset_workspace

# Expose Postgres port
EXPOSE 5432

# Start PostgreSQL service as the postgres user
USER postgres
RUN /usr/lib/postgresql/17/bin/initdb -D /var/lib/postgresql/data
CMD ["/usr/lib/postgresql/17/bin/postgres", "-D", "/var/lib/postgresql/data"]

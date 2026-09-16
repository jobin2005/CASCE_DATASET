FROM postgres:16

COPY init-all-dbs.sh /docker-entrypoint-initdb.d/init-all-dbs.sh
RUN chmod +x /docker-entrypoint-initdb.d/init-all-dbs.sh

COPY dbs /docker-entrypoint-initdb.d/dbs
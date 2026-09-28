# ETL-Synthea pinned on linux/amd64 (R 4.3.3 + Java ETL-Synthea 2.1.1).
FROM rocker/r-ver:4.3.3@sha256:20ede1f846d2423b483b1019a499cc0f8c1d15192f47812c92d0900af4029039
RUN apt-get update && apt-get install -y --no-install-recommends \
    default-jdk-headless postgresql-client python3 openssl util-linux \
    libcurl4-openssl-dev libssl-dev libxml2-dev libuv1-dev \
    libbz2-dev liblzma-dev libpcre2-dev zlib1g-dev pkg-config \
  && rm -rf /var/lib/apt/lists/* \
  && R CMD javareconf
ARG ETLSYNTHEA_VERSION=2.1.1
# Resolved SHA-256 pinned at implementation time, verified below:
# curl -sL https://github.com/OHDSI/ETL-Synthea/archive/refs/tags/v2.1.1.tar.gz | sha256sum
ARG ETLSYNTHEA_SHA256=76c4104d2d89ce73e1cc4f0ac00c3937cd684e2f19cd871cdcee423853beb126
ADD https://github.com/OHDSI/ETL-Synthea/archive/refs/tags/v${ETLSYNTHEA_VERSION}.tar.gz /opt/etl-synthea.tar.gz
RUN echo "${ETLSYNTHEA_SHA256}  /opt/etl-synthea.tar.gz" | sha256sum -c - \
  && mkdir -p /opt/etl-synthea && tar xzf /opt/etl-synthea.tar.gz -C /opt/etl-synthea --strip-components=1
# PostgreSQL JDBC driver for DatabaseConnector (R uses JDBC, not libpq).
ARG PGJDBC_VERSION=42.7.4
ARG PGJDBC_SHA256=188976721ead8e8627eb6d8389d500dccc0c9bebd885268a3047180274a6031e
ADD https://jdbc.postgresql.org/download/postgresql-${PGJDBC_VERSION}.jar /opt/jdbc/postgresql.jar
RUN echo "${PGJDBC_SHA256}  /opt/jdbc/postgresql.jar" | sha256sum -c -
RUN R -e 'install.packages(c("DatabaseConnector","SqlRender","CommonDataModel","dplyr","readr","data.table","httr"), repos="https://cloud.r-project.org")' \
  && R CMD INSTALL /opt/etl-synthea.tar.gz
COPY run.sh run_etl.R assemble.py clean.sql /opt/etl-synthea/job/
RUN chmod +x /opt/etl-synthea/job/run.sh
ENTRYPOINT ["/opt/etl-synthea/job/run.sh"]

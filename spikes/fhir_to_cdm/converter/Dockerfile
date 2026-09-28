# Unmodified upstream build. No sed/patch/retarget of FhirToCdm source.
# Base images are Debian buster (EOL); apt points at the archive mirror.
ARG FHIR_TO_CDM_REF=4991f907ba075cb5875020b3a83995ba15185dae
FROM mcr.microsoft.com/dotnet/core/sdk:3.1 AS build
ARG FHIR_TO_CDM_REF
RUN sed -i 's|http://deb.debian.org/debian|http://archive.debian.org/debian|g' /etc/apt/sources.list \
 && sed -i 's|http://security.debian.org|http://archive.debian.org/debian-security|g' /etc/apt/sources.list \
 && sed -i '/buster-updates/d' /etc/apt/sources.list \
 && apt-get -o Acquire::Check-Valid-Until=false update \
 && apt-get -o Acquire::Check-Valid-Until=false install -y --no-install-recommends git \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git clone https://github.com/OHDSI/FhirToCdm.git . \
 && git checkout --detach "$FHIR_TO_CDM_REF" \
 && git rev-parse HEAD > /opt-commit.txt \
 && dotnet restore \
 && dotnet publish -c Release -r linux-x64 -o /publish

FROM mcr.microsoft.com/dotnet/core/runtime:3.1 AS runtime
RUN sed -i 's|http://deb.debian.org/debian|http://archive.debian.org/debian|g' /etc/apt/sources.list \
 && sed -i 's|http://security.debian.org|http://archive.debian.org/debian-security|g' /etc/apt/sources.list \
 && sed -i '/buster-updates/d' /etc/apt/sources.list \
 && apt-get -o Acquire::Check-Valid-Until=false update \
 && apt-get -o Acquire::Check-Valid-Until=false install -y --no-install-recommends unixodbc odbc-postgresql \
 && rm -rf /var/lib/apt/lists/* \
 && useradd -m spike
COPY --from=build /publish /opt/fhir-to-cdm/
COPY --from=build /opt-commit.txt /opt/fhir-to-cdm/UPSTREAM_COMMIT
# Linux filesystem adaptation (no upstream content changed):
# upstream Vocabulary.cs reads @"Lookups\Base.sql" (Windows separator) as the
# shared template while enumerating "Lookups/" and skipping that same literal.
# On Linux the backslash names a different file and the skip never matches, so
# Base.sql would load as a query fragment and fail. Move the forward-slash copy
# aside (bytes preserved) and expose identical bytes under the backslash name
# the program asks for; enumeration then sees only the five real lookups.
RUN mv /opt/fhir-to-cdm/Lookups/Base.sql /opt/fhir-to-cdm/Base.sql.ref \
 && BS="$(printf '\134')" \
 && ln -s Base.sql.ref "/opt/fhir-to-cdm/Lookups${BS}Base.sql" \
 && ls -b /opt/fhir-to-cdm \
 && sha256sum /opt/fhir-to-cdm/Base.sql.ref "/opt/fhir-to-cdm/Lookups${BS}Base.sql"
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
# Alias matching the exact driver name in the FhirToCdm README template
# (odbcinst lookup is case-sensitive; Debian registers 'PostgreSQL Unicode').
RUN printf '\n[PostgreSQL UNICODE]\nDescription=Alias for PostgreSQL Unicode driver\nDriver=psqlodbcw.so\nSetup=libodbcpsqlS.so\n' >> /etc/odbcinst.ini \
 && odbcinst -q -d
RUN chmod +x /usr/local/bin/entrypoint.sh
WORKDIR /opt/fhir-to-cdm
USER spike
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# Synthea 3.3.0 generator, linux/amd64. Pin the base-image digest at implementation time.
FROM eclipse-temurin:17-jre-jammy@sha256:97137382c6f0c30427d9b7c44ad8b2d55ac823b0768c171d81a643ed219023c5
ARG SYNTHEA_VERSION=3.3.0
# Resolve the real SHA at implementation time and pin it here:
# curl -sL https://github.com/synthetichealth/synthea/releases/download/v3.3.0/synthea-with-dependencies.jar | sha256sum
ARG SYNTHEA_SHA256=8ba04f7d73abadd5a377e41edf24c5c83935a1cb07c6d982cd5db731ef1cf445
RUN apt-get update && apt-get install -y --no-install-recommends python3 \
 && rm -rf /var/lib/apt/lists/*
ADD https://github.com/synthetichealth/synthea/releases/download/v${SYNTHEA_VERSION}/synthea-with-dependencies.jar /opt/synthea/synthea.jar
RUN echo "${SYNTHEA_SHA256}  /opt/synthea/synthea.jar" | sha256sum -c - \
 && mkdir -p /tmp/synthea-out /data/csv_input /data/fhir_input
COPY generate.sh publish.sh /opt/synthea/
RUN chmod +x /opt/synthea/generate.sh /opt/synthea/publish.sh
ENTRYPOINT ["/opt/synthea/generate.sh"]

FROM eclipse-temurin:17-jre-jammy
ARG SYNTHEA_VERSION=3.3.0
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /opt/synthea \
 && curl -fL -o /opt/synthea/synthea-with-dependencies.jar \
      "https://github.com/synthetichealth/synthea/releases/download/v${SYNTHEA_VERSION}/synthea-with-dependencies.jar" \
 && sha256sum /opt/synthea/synthea-with-dependencies.jar | tee /opt/synthea/SHA256SUM \
 && useradd -m spike
COPY generate.sh /usr/local/bin/generate.sh
RUN chmod +x /usr/local/bin/generate.sh
USER spike
ENTRYPOINT ["/usr/local/bin/generate.sh"]

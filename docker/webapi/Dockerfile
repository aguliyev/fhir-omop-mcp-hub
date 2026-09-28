# OHDSI WebAPI v2.15.2 on Tomcat 9 + Java 11 (javax.servlet; Tomcat 10/jakarta
# will NOT work; JRE 17 breaks the bundled cosium entity-graph lib which reads
# the JDK-internal Field.modifiers removed after Java 11).
# Pinned by digest (linux/amd64). See PROVENANCE.md.
FROM tomcat:9-jre11@sha256:65ea4ebaa64d9ee9b109a6d130e1c5c3b55a172756c6fd20558d2caa26a0d6a2
# Pinned release artifact; build fails without matching values.
ARG WEBAPI_WAR_URL=https://github.com/OHDSI/WebAPI/releases/download/v2.15.2/WebAPI.war
ARG WEBAPI_SHA256=e544c181138c5e1eef09c36c9310ed78ba41d649f6be72e30eb2d67aace11b7d
ADD ${WEBAPI_WAR_URL} /tmp/WebAPI.war
# curl is used by the compose healthcheck; default webapps are removed to
# shrink the surface. The WAR is deployed whole (Tomcat explodes it); no
# files are injected into the webapp.
RUN echo "${WEBAPI_SHA256}  /tmp/WebAPI.war" | sha256sum -c - \
  && rm -rf /usr/local/tomcat/webapps/ROOT /usr/local/tomcat/webapps/docs \
     /usr/local/tomcat/webapps/examples /usr/local/tomcat/webapps/host-manager \
     /usr/local/tomcat/webapps/manager \
  && mv /tmp/WebAPI.war /usr/local/tomcat/webapps/WebAPI.war \
  && apt-get update && apt-get install -y --no-install-recommends curl \
  && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]

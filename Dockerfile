FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      openvpn tinyproxy iproute2 curl psmisc gettext-base && \
    rm -rf /var/lib/apt/lists/*

COPY start.sh /usr/local/bin/start.sh
COPY tinyproxy.conf.template /etc/tinyproxy/tinyproxy.conf.template

RUN chmod +x /usr/local/bin/start.sh

ENTRYPOINT ["/usr/local/bin/start.sh"]

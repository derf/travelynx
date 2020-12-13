FROM debian:stretch-slim

ARG DEBIAN_FRONTEND=noninteractive

COPY cpanfile* /app/
WORKDIR /app

RUN apt-get update && apt-get install --no-install-recommends -y \
	ca-certificates \
	cpanminus \
	gcc \
	git \
	libc6-dev \
	libdb5.3 \
	libdb5.3-dev \
	libpq-dev \
	libssl1.1 \
	libssl-dev \
	libxml2 \
	libxml2-dev \
	make \
	zlib1g-dev \
	&& cpanm -in --no-man-pages --installdeps . \
	&& rm -rf ~/.cpanm \
	&& apt-get purge -y \
	cpanminus \
	curl \
	gcc \
	libc6-dev \
	libdb5.3-dev \
	libssl-dev \
	libxml2-dev \
	make \
	zlib1g-dev \
	&& apt-get autoremove -y

COPY . /app

CMD ["/app/docker-run.sh"]

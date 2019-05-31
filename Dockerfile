FROM debian:stretch-slim

ARG DEBIAN_FRONTEND=noninteractive

COPY cpanfile /app/cpanfile
WORKDIR /app

RUN apt-get update && apt-get install --no-install-recommends -y \
	cpanminus \
	build-essential \
	libpq-dev \
	git \
	&& cpanm -in --no-man-pages --installdeps . \
	&& rm -rf ~/.cpanm \
	&& apt-get purge -y \
	build-essential \
	cpanminus \
	&& apt-get autoremove -y

COPY . /app

CMD ["/app/docker-run.sh"]

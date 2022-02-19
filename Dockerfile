FROM debian:buster-slim as files

ARG travelynx_version=git

COPY docker-run.sh /app/
COPY index.pl /app/
COPY lib/ /app/lib/
COPY public/ /app/public/
COPY templates/ /app/templates/
COPY share/ /app/share/

WORKDIR /app

RUN ln -sf ../local/imprint.html.ep templates && \
	ln -sf ../local/privacy.html.ep templates && \
	ln -sf ../local/travelynx.conf

RUN sed -i "s/qx{git describe --dirty}/'${travelynx_version}'/" lib/Travelynx/Controller/Static.pm
RUN sed -i "s/\$self->plugin('Config');/\$self->plugin('Config'); \$self->config->{version} = '${travelynx_version}';/" lib/Travelynx.pm

FROM perl:5.30-slim

ARG DEBIAN_FRONTEND=noninteractive
ARG APT_LISTCHANGES_FRONTEND=none

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
	&& apt-get autoremove -y \
	&& rm -rf /var/cache/apt/* /var/lib/apt/lists/*

COPY --from=files /app/ /app/

EXPOSE 8093

ENTRYPOINT ["/app/docker-run.sh"]

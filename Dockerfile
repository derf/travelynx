FROM debian:stretch

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install --no-install-recommends -y \
	cpanminus \
	build-essential \
	libpq-dev \
	git \
	ssmtp \
	&& cpanm -in \
	Cache::File \
	Crypt::Eksblowfish \
	DateTime \
	DateTime::Format::Strptime \
	DBI \
	DBD::Pg \
	Email::Sender \
	Geo::Distance \
	Geo::Distance::XS \
	Mojolicious \
	Mojolicious::Plugin::Authentication \
	Travel::Status::DE::IRIS \
	UUID::Tiny \
	JSON \
	&& rm -rf ~/.cpanm \
	&& apt-get purge -y \
	build-essential \
	cpanminus \
	&& apt-get autoremove -y

COPY . /app
WORKDIR /app

CMD /app/docker-run.sh
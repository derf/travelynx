FROM debian:stretch

RUN apt-get update && apt-get install -y \
	cpanminus \
	build-essential \
	libpq-dev \
	git \
	ssmtp

RUN cpanm -in \
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
	JSON

COPY . /app
WORKDIR /app


CMD /app/docker-run.sh
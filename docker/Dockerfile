FROM alpine:3.15

ARG uid  1000
ARG gid 1000

MAINTAINER Ralf Becker <beckerr@hochschule-trier.de>

RUN apk add --no-cache perl perl-io-socket-ssl perl-data-dump perl-cache-cache perl-convert-asn1 \
		perl-net-ldap perl-yaml perl-ipc-sharelite perl-error perl-crypt-cbc perl-crypt-openssl-aes \
		perl-mime-base64 perl-cryptx perl-digest-sha1 perl-sys-syslog

ADD ./ldap-dynamic-rewriter /opt/ldap-dynamic-rewriter
WORKDIR /opt/ldap-dynamic-rewriter
VOLUME  /opt/ldap-dynamic-rewriter/log

RUN addgroup -S ldap-dr -g $gid && adduser -S ldap-dr -u $uid -G ldap-dr && id ldap-dr &&\
	mkdir cache && chown ldap-dr:ldap-dr cache log

USER ldap-dr

EXPOSE 1389 1636

ENTRYPOINT ["./bin/ldap-rewrite.pl"]

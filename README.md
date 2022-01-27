# LDAP Dynamic Rewriter

LDAP Dynamic Rewriter is set of perl scripts which allows you to augment data in your
existing LDAP server (which you don't want to modify) using `ldap-rewrite.pl`
(supporting rewrite of bind request, search requests and responses).

## Installation

Depends
```
apt-get install libio-socket-ssl-perl libdata-dump-perl libconvert-asn1-perl libnet-ldap-perl libyaml-perl 
```

Install with:
```
cd /srv
https://github.com/beckerr-rzht/ldap-dynamic-rewriter.git
```

Default config:
```
cd ldap-dynamic-rewriter 
cp etc/config.yaml.template etc/config.yaml
```

Configure:
```
vi etc/config.yaml
```

## Usage

If you need to augment or mungle LDAP from upstream server start:
```
./bin/ldap-rewrite.pl
```

## Rewrites

### Perl
Write Perl modules that implements the rewrites and place them in
`./infilter` or `./outfilter`. See `outfilter/addGidNumber.pm` for
an example.

### YAML
You might want to edit configuration at top of script itself, especially
overlay_prefix if you want your YAML data to be without it.

To augment data with your own, you should create files
```
yaml/uid=login,dc=example,dc=com
```

## Test

If you have test user in your LDAP edit configuration file and run tests:
```
cp t/config.pl.template t/config.pl
vi t/config.pl
./t/ldap-rewrite.t
```

## Further notes and recommandation

Accessing a Koha Database is no longer support by this repository.
The relevant code and examples may disappear at any time. 


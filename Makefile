dist:
	cpanm -n -l dzil-local Dist::Zilla
	PATH=$(PATH):dzil-local/bin PERL5LIB=dzil-local/lib/perl5 dzil authordeps --missing | cpanm -n -l dzil-local/
	PATH=$(PATH):dzil-local/bin PERL5LIB=dzil-local/lib/perl5 dzil build


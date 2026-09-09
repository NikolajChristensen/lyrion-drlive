#!/usr/bin/env perl
# Unit test for Plugins::DRLive::API::_logo, loaded in isolation.
#
# This helper is easy to break invisibly: DR's image URLs carry a literal
# "$value" path segment and single-quoted parameter values, and if either is
# mangled DR returns nothing and artwork just never appears - no error anywhere.
use strict;
use warnings;

my $src = do {
	local $/;
	open my $fh, '<', 'Plugins/DRLive/API.pm' or die $!;
	<$fh>;
};
my ($helper) = $src =~ /(sub _logo\b.*?\n})/s;
die "could not extract _logo\n" unless $helper;
eval "package T; use constant LOGO_PX => 300; $helper 1;" or die "compile: $@";

my $ok = 1;
sub is {
	my ($got, $exp, $name) = @_;
	if (defined $got && $got eq $exp) { print "ok   - $name\n" }
	else { $ok = 0; print "FAIL - $name\n     got: ", $got // '(undef)', "\n     exp: $exp\n" }
}

my $real = q{https://prod95-static.dr-massive.com/api/shain/v1/dataservice/ResizeImage/$value?Format='png'&Quality=85&EntityType='Item'&EntityId='20875'&Width=2160&Height=2160&ImageId='2344194'};
my $want = q{https://prod95-static.dr-massive.com/api/shain/v1/dataservice/ResizeImage/$value?Format='png'&Quality=85&EntityType='Item'&EntityId='20875'&Width=300&Height=300&ImageId='2344194'};

is(T::_logo({ logo => $real }), $want, 'rewrites Width/Height, preserves $value and quoting');

my $r = T::_logo({ logo => $real });
print +($r =~ /\$value/ ? "ok   - literal \$value survives\n" : do { $ok = 0; "FAIL - \$value was mangled\n" });
print +($r =~ /EntityId='20875'/ ? "ok   - single quotes survive\n" : do { $ok = 0; "FAIL - quoting was mangled\n" });

is(T::_logo({ square => $real }), $want, 'falls back to square when logo is absent');
is(T::_logo({ tile   => $real }), $want, 'falls back to tile');

{
	my $none = T::_logo({});
	print +(!defined $none ? "ok   - undef when no usable image\n" : do { $ok = 0; "FAIL - expected undef, got $none\n" });
	my $nil = T::_logo(undef);
	print +(!defined $nil ? "ok   - undef when images hash is missing\n" : do { $ok = 0; "FAIL - expected undef\n" });
}

# A URL without size parameters must pass through rather than be corrupted.
my $plain = 'https://example.net/logo.png';
is(T::_logo({ logo => $plain }), $plain, 'leaves a URL with no size parameters alone');

exit($ok ? 0 : 1);

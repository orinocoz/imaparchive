#!/usr/bin/env perl
use Modern::Perl;
use autodie;
use Mail::IMAPClient;
use Date::Parse;
use Carp;
use IO::Socket::SSL;
use Config::Simple;
use Getopt::Long qw(:config auto_version);

our $VERSION = "0.01";

my $server;
my $user;
my $password;
my $root;
my $archiveprefix;
my $agediff;
my $configfile;
my $config = new Config::Simple();

GetOptions(
    "server|s:s"                  => \$server,
    "user|u:s"                    => \$user,
    "password|pw|p:s"             => \$password,
    "root|r:s"                    => \$root,
    "archiveprefix|prefix|ap|p:s" => \$archiveprefix,
    "agediff|ad|a:2678400"        => \$agediff,
    "config|c:s"                  => \$configfile
);

if ( !defined($configfile) ) {
    croak "Server needed."   unless defined($server);
    croak "Username needed." unless defined($user);
    croak "Password needed." unless defined($password);
    $root          = 'INBOX'   unless defined($root);
    $archiveprefix = 'Archive' unless defined($archiveprefix);
    $agediff       = 2678400   unless defined($archiveprefix);
}
else {
    $config->read($configfile) or croak $config->error();
    $server        = $config->param('server');
    $user          = $config->param('user');
    $password      = $config->param('password');
    $root          = $config->param('root');
    $archiveprefix = $config->param('archiveprefix');
    $agediff       = $config->param('agediff');
}

# This will be our foldercache to save lots of IMAP calls
my %folderCache;
my %moveHash;

# Create an IMAPClient object
my $imap = Mail::IMAPClient->new(
    Server => $server,
    Socket => IO::Socket::SSL->new(
        Proto           => 'tcp',
        PeerAddr        => $server,
        PeerPort        => 993,
        SSL_verify_mode => SSL_VERIFY_NONE,
    ),

    # Debug    => "yes, please",
    # Debug_fh => IO::File->new(">debug.out"),
) or croak "Error connecting: " . $@;

$imap->User($user) or croak "Error setting user: " . $imap->LastError;
$imap->Password($password)
  or croak "Error setting password: " . $imap->LastError;

if ( $imap->has_capability("STARTTLS") ) {
    $imap->starttls or carp "Cannot STARTTLS: " . $imap->LastError;
}
if ( $imap->has_capability("AUTH=CRAM-MD5") ) {
    $imap->Authmechanism("CRAM-MD5")
      or carp "Cannot set authmechanism: " . $imap->LastError;
}

$imap->login;

$imap->select($root) or croak "Error switching to $root: " . $imap->LastError;
my $separator = $imap->separator
  or croak "Error retrieving separator: " . $imap->LastError;

# We are in INBOX now, get list of messages
my $archivetime = time - $agediff;

my @messages = $imap->before( $imap->Rfc3501_date($archivetime) );
if ( $imap->LastError ) {
    croak "Error getting list of messages: " . $imap->LastError;
}
if ( !scalar @messages ) {
    say "No messages found.";
    exit 0;
}
say "Checking " . scalar(@messages) . " messages.";

# For every message
my $numOfMessages = 0;
my $numMoved      = 0;
local $| = 1;
for my $message (@messages) {
    $numOfMessages++;
    ## Find received date
    my $deliveryDate = $imap->get_header( $message, "Delivery-Date" )
      or $imap->get_header( $message, "Date" );
    if ( !defined($deliveryDate) ) {
        carp "Error getting header: ", $imap->LastError;
        next;
    }
    $deliveryDate = str2time($deliveryDate);
    if ( $deliveryDate <= $archivetime ) {
        my ( undef, undef, undef, undef, $deliveryMonth, $deliveryYear, undef,
            undef, undef )
          = localtime($deliveryDate);

        # I thought we crossed y2k already, why such a buggy implementation?
        $deliveryYear += 1900;

        # Wow, 0 based months
        $deliveryMonth += 1;
        ## Make sure Archive mailbox exists
        my $archiveFolder =
          createArchiveFolder( $deliveryYear, $deliveryMonth );
        ## Create hash of messages to be moved into which folder
        $moveHash{$archiveFolder} .= $message . ",";
        $numMoved++;
    }
    else {
        croak("Message was younger than asked for via before()");
    }
    if ( 0 == $numOfMessages % 10 ) {
        print ".";
    }
}
print "\n";
local $| = 0;
say "$numMoved/$numOfMessages identified.";

# Do we have to move anything at all?
if ( 0 < $numMoved ) {
    say "Moving...";
    foreach my $af ( keys(%moveHash) ) {
        my $uids = $moveHash{$af};
        chop $uids;
        $imap->move( $af, $uids )
          or carp "Error moving: " . $imap->LastError;
    }

    # Don't forget to expunge ^^
    $imap->expunge or croak "Error expunging: " . $imap->LastError;
}

# say goodbye
say "Done.";
$imap->disconnect;

sub createArchiveFolder {
    my $year  = shift;
    my $month = shift;

    # Check existence of the bottom most folder
    # Since we use the hash cache this should give the largest hit ratio
    my $folderName = join( $separator, $root, $archiveprefix, $year, $month );
    if ( 1 == folderExists($folderName) ) {
        return $folderName;
    }

  # The bottom most folder did not exist
  # Now we need to check form the root on if all the needed parent folders exist
  # or create them
    $folderName = join( $separator, $root, $archiveprefix );
    if ( 0 == folderExists($folderName) ) {
        $imap->create($folderName)
          or carp "Error creating folder $folderName: " . $imap->LastError;
    }
    $folderName = join( $separator, $root, $archiveprefix, $year );
    if ( 0 == folderExists($folderName) ) {
        $imap->create($folderName)
          or carp "Error creating folder $folderName: " . $imap->LastError;
    }
    $folderName = join( $separator, $root, $archiveprefix, $year, $month );
    $imap->create($folderName)
      or carp "Error creating folder $folderName: " . $imap->LastError;

    # Phew, done, here you go
    return $folderName;
}

sub folderExists {
    my $folder = shift;

    # Do we have the existence of the folder cached?
    if ( exists $folderCache{$folder} && 1 == $folderCache{$folder} ) {
        return 1;
    }

    # Check if the folder exists
    if ( $imap->exists($folder) ) {

        # It exists? Then update the hash cache
        $folderCache{$folder} = 1;
        return 1;
    }

    # Sorry, folder doesn't exist
    return 0;
}

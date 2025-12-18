# quests/plugins/check_handin.pl
package plugin;

# ================================================================
# check_handin.pl (DROP-IN, COMPAT-SAFE, 4-slot trade window + money)
#
# Goals:
#  - Preserve existing quest behavior by default (NO auto item scaling)
#  - Provide opt-in scaling:
#       * coin_scale => <pp per set>   (already opt-in)
#       * item_scale => 1             (opt-in bulk for single item req=1)
#  - Safer defaults:
#       * coin_scale defaults to no_items=1 (coins-only) unless explicitly no_items=>0
#       * scaling supports max_sets (default 10 when scaling enabled)
#       * optional strict_trade => 1 (reject extra items/coins not in recipe)
#  - Debug in GREEN (Message color 14)
#  - Safe returns using engine: $npc->ReturnHandinItems($client) (no dupes)
#
# Return values:
#  - scale success (coin_scale/item_scale): list -> (1, sets) scalar -> 1
#  - normal success:                       list -> (1, 0)    scalar -> 1
#  - failure:                              list -> (0, 0)    scalar -> 0
#
# Debug enable:
#  - pass debug => 1 in plugin::check_handin(...)
#  - OR set env EQEMU_HANDIN_DEBUG=1
# ================================================================

my $DBG_COLOR = 14; # green

# ---------------- debug helpers ----------------
sub _debug_enabled {
    my ($opt) = @_;
    return 1 if $ENV{EQEMU_HANDIN_DEBUG} && $ENV{EQEMU_HANDIN_DEBUG} ne '0';
    return 1 if $opt && ref($opt) eq 'HASH' && $opt->{debug};
    return 0;
}

sub _dbg {
    my ($opt, $msg) = @_;
    return if !_debug_enabled($opt);
    $msg = "" if !defined $msg;
    $msg =~ s/\r?\n/ /g;

    my $client = plugin::val('client');
    if ($client && $client->IsClient()) {
        $client->Message($DBG_COLOR, "[check_handin] $msg");
    } else {
        quest::say("[check_handin] $msg");
    }
}

# ---------------- helpers ----------------
sub _read_coins {
    my $p = $main::platinum // 0;
    my $g = $main::gold     // 0;
    my $s = $main::silver   // 0;
    my $c = $main::copper   // 0;

    # Fallbacks (some builds)
    if (($p + $g + $s + $c) <= 0) {
        my $vp = plugin::val('$platinum'); $vp = plugin::val('platinum') if !defined $vp; $p = $vp if defined $vp;
        my $vg = plugin::val('$gold');     $vg = plugin::val('gold')     if !defined $vg; $g = $vg if defined $vg;
        my $vs = plugin::val('$silver');   $vs = plugin::val('silver')   if !defined $vs; $s = $vs if defined $vs;
        my $vc = plugin::val('$copper');   $vc = plugin::val('copper')   if !defined $vc; $c = $vc if defined $vc;

        $p ||= 0; $g ||= 0; $s ||= 0; $c ||= 0;
    }

    return (int($p||0), int($g||0), int($s||0), int($c||0));
}

sub _strip_zero_item_reqs {
    my ($h) = @_;
    return if !$h || ref($h) ne 'HASH';
    for my $k (keys %$h) {
        next if $k =~ /^(platinum|gold|silver|copper)$/;
        delete $h->{$k} if !defined($h->{$k}) || $h->{$k} <= 0;
    }
}

# 4-slot trade window instances
sub _item_instances_4 {
    return (
        plugin::val('item1_inst'), plugin::val('item2_inst'),
        plugin::val('item3_inst'), plugin::val('item4_inst'),
    );
}

# Build offered counts from actual 4 trade slots (stack-safe)
sub _build_offered_from_slots_4 {
    my ($opt) = @_;
    my %offered;

    for my $n (1..4) {
        my $id = plugin::val("item${n}");
        next if !$id || $id == 0;

        my $inst = plugin::val("item${n}_inst");
        my $chg  = plugin::val("item${n}_charges");

        my $qty = 0;
        if ($inst && ref($inst) && eval { $inst->can('GetCharges') }) {
            $qty = int($inst->GetCharges() || 0);
        } else {
            $qty = int($chg || 0);
        }

        # Non-stackables / odd reporting => treat as 1 item
        $qty = 1 if $qty <= 0;

        $offered{$id} += $qty;
        _dbg($opt, "slot $n id=$id qty=$qty (running total=$offered{$id})");
    }

    return \%offered;
}

sub _strict_trade_check {
    my ($opt, $offered_ref, $required_ref, $coins_ref) = @_;
    # offered_ref: item counts
    # required_ref: item reqs (already stripped)
    # coins_ref: {platinum=>p, gold=>g, silver=>s, copper=>c} offered
    #
    # Rule: if ANY offered item/coin isn't explicitly part of required, fail.

    # Items
    for my $id (keys %$offered_ref) {
        return 0 if !exists $required_ref->{$id};
    }

    # Coins: only allow if explicitly required (exact) OR if coin_scale mode handles it
    for my $ck (qw(platinum gold silver copper)) {
        my $v = $coins_ref->{$ck} || 0;
        next if $v <= 0;
        return 0 if !exists $required_ref->{$ck}; # must be explicitly required
    }

    return 1;
}

# ================================================================
# plugin::check_handin(\%itemcount, ...requirements/options...)
# ================================================================
sub check_handin {
    my $hashref  = shift;
    my %required = @_;

    my $client = plugin::val('client');
    my $npc    = plugin::val('npc');

    return wantarray ? (0, 0) : 0 if !$client || !$npc;
    return wantarray ? (0, 0) : 0 if ref($hashref) ne 'HASH';

    my $opt = {};
    $opt->{debug} = delete $required{debug} if exists $required{debug};

    my $strict_trade = delete $required{strict_trade} ? 1 : 0;

    my ($p,$g,$s,$c) = _read_coins();
    my $total_cp = ($p*1000)+($g*100)+($s*10)+$c;

    my @item_insts = _item_instances_4();

    _dbg($opt, "ENTER coins p=$p g=$g s=$s c=$c total_cp=$total_cp strict_trade=$strict_trade");

    # =========================================================
    # coin_scale mode (explicit) - defaults no_items=1 (coins-only)
    # =========================================================
    if (exists $required{coin_scale}) {
        my $base_p = delete $required{coin_scale};

        # coin_scale defaults to NO ITEMS unless explicitly overridden
        my $no_items = exists($required{no_items})
            ? (delete($required{no_items}) ? 1 : 0)
            : 1;

        my $min_sets = defined($required{min_sets}) ? int(delete $required{min_sets}) : 1;

        # SAFER DEFAULT: cap sets unless explicitly provided
        my $max_sets = defined($required{max_sets}) ? int(delete $required{max_sets}) : 10;

        my $unit_cp = int(($base_p||0) * 1000);
        _dbg($opt, "coin_scale base_p=$base_p unit_cp=$unit_cp min_sets=$min_sets max_sets=$max_sets no_items=$no_items");

        return wantarray ? (0,0) : 0 if $unit_cp <= 0;

        my $offered_items = _build_offered_from_slots_4($opt);

        if ($no_items && keys %$offered_items) {
            _dbg($opt, "REJECT coin_scale: no_items=1 but items were handed in");
            return wantarray ? (0,0) : 0;
        }

        my $sets = int($total_cp / $unit_cp);
        _dbg($opt, "coin_scale computed sets=$sets");

        return wantarray ? (0,0) : 0 if $sets < $min_sets;
        return wantarray ? (0,0) : 0 if defined($max_sets) && $sets > $max_sets;

        # exact multiple only
        if (($total_cp % $unit_cp) != 0) {
            _dbg($opt, "REJECT coin_scale: not exact multiple (total_cp=$total_cp unit_cp=$unit_cp)");
            return wantarray ? (0,0) : 0;
        }

        # offered = offered items (if allowed) + exact offered coin denoms
        my %offered = %{$offered_items};
        $offered{platinum} = $p if $p;
        $offered{gold}     = $g if $g;
        $offered{silver}   = $s if $s;
        $offered{copper}   = $c if $c;

        # need items (optional) + exact offered coin denoms
        my %need = %required;
        _strip_zero_item_reqs(\%need);

        $need{platinum} = $p;
        $need{gold}     = $g;
        $need{silver}   = $s;
        $need{copper}   = $c;

        # strict_trade: ONLY allow items explicitly required (coins are required by definition here)
        if ($strict_trade) {
            # In coin_scale, coins are always part of need; allow optional required items only.
            my %need_for_strict = %need;
            my %coins_offered = (platinum=>$p, gold=>$g, silver=>$s, copper=>$c);
            if (!_strict_trade_check($opt, $offered_items, \%need_for_strict, \%coins_offered)) {
                _dbg($opt, "REJECT coin_scale: strict_trade failed (extra items/coins)");
                return wantarray ? (0,0) : 0;
            }
        }

        _dbg($opt, "CALL CheckHandin coin_scale need coins p=$need{platinum} g=$need{gold} s=$need{silver} c=$need{copper}");

        if ($npc->CheckHandin($client, \%offered, \%need, @item_insts)) {
            _dbg($opt, "SUCCESS coin_scale sets=$sets");
            return wantarray ? (1, $sets) : 1;
        }

        _dbg($opt, "FAIL coin_scale (CheckHandin returned false)");
        return wantarray ? (0,0) : 0;
    }

    # =========================================================
    # item_scale mode (OPT-IN ONLY) - safe bulk for single item req=1
    # =========================================================
    if (delete $required{item_scale}) {
        my @req_items = grep { $_ !~ /^(platinum|gold|silver|copper)$/ } keys %required;

        # SAFER DEFAULT: cap sets unless explicitly provided
        my $max_sets = defined($required{max_sets}) ? int(delete $required{max_sets}) : 10;

        if (@req_items == 1 && ($required{$req_items[0]}||0) == 1) {
            my $item_id = $req_items[0];

            my $offered_ref = _build_offered_from_slots_4($opt);
            my $handed_qty  = int($offered_ref->{$item_id} || 0);

            _dbg($opt, "item_scale ON item=$item_id handed_qty=$handed_qty max_sets=$max_sets");

            if ($handed_qty > 0) {
                my $sets = $handed_qty; # req=1
                $sets = $max_sets if defined($max_sets) && $sets > $max_sets;

                # Consume only up to cap (if capped)
                my %need = ( $item_id => $sets );
                $offered_ref->{$item_id} = $handed_qty; # offered remains true quantity

                # strict_trade: reject extra items / any coins
                if ($strict_trade) {
                    my %need_for_strict = ( $item_id => 1 );
                    my %coins_offered = (platinum=>$p, gold=>$g, silver=>$s, copper=>$c);
                    if (!_strict_trade_check($opt, $offered_ref, \%need_for_strict, \%coins_offered)) {
                        _dbg($opt, "REJECT item_scale: strict_trade failed (extra items/coins)");
                        return wantarray ? (0,0) : 0;
                    }
                }

                if ($npc->CheckHandin($client, $offered_ref, \%need, @item_insts)) {
                    _dbg($opt, "SUCCESS item_scale sets=$sets (consumed that many)");
                    return wantarray ? (1, $sets) : 1;
                }

                _dbg($opt, "FAIL item_scale (CheckHandin false)");
            }
        } else {
            _dbg($opt, "REJECT item_scale: must be exactly one required item with qty=1");
        }

        return wantarray ? (0,0) : 0;
    }

    # =========================================================
    # exact coin mode (only if coin keys are present in required)
    # =========================================================
    my $wants_exact_coin = (exists($required{platinum}) || exists($required{gold}) || exists($required{silver}) || exists($required{copper})) ? 1 : 0;

    if ($wants_exact_coin) {
        my $rp = delete($required{platinum}) || 0;
        my $rg = delete($required{gold})     || 0;
        my $rs = delete($required{silver})   || 0;
        my $rc = delete($required{copper})   || 0;

        if ($p != $rp || $g != $rg || $s != $rs || $c != $rc) {
            _dbg($opt, "REJECT exact coin: offered p=$p g=$g s=$s c=$c != req p=$rp g=$rg s=$rs c=$rc");
            return wantarray ? (0,0) : 0;
        }

        my $offered_ref = _build_offered_from_slots_4($opt);
        $offered_ref->{platinum} = $p if $p;
        $offered_ref->{gold}     = $g if $g;
        $offered_ref->{silver}   = $s if $s;
        $offered_ref->{copper}   = $c if $c;

        _strip_zero_item_reqs(\%required);

        my %need = (%required, platinum => $rp, gold => $rg, silver => $rs, copper => $rc);

        if ($strict_trade) {
            my %coins_offered = (platinum=>$p, gold=>$g, silver=>$s, copper=>$c);
            if (!_strict_trade_check($opt, $offered_ref, \%need, \%coins_offered)) {
                _dbg($opt, "REJECT exact coin: strict_trade failed (extra items/coins)");
                return wantarray ? (0,0) : 0;
            }
        }

        _dbg($opt, "CALL CheckHandin exact-coin");

        if ($npc->CheckHandin($client, $offered_ref, \%need, @item_insts)) {
            _dbg($opt, "SUCCESS exact-coin");
            return wantarray ? (1, 0) : 1;
        }

        _dbg($opt, "FAIL exact-coin");
        return wantarray ? (0,0) : 0;
    }

    # =========================================================
    # NORMAL MODE (legacy-like)
    # =========================================================
    my $offered_ref = _build_offered_from_slots_4($opt);

    # include coins (harmless unless strict_trade is on)
    $offered_ref->{platinum} = $p if $p;
    $offered_ref->{gold}     = $g if $g;
    $offered_ref->{silver}   = $s if $s;
    $offered_ref->{copper}   = $c if $c;

    _strip_zero_item_reqs(\%required);

    if ($strict_trade) {
        my %coins_offered = (platinum=>$p, gold=>$g, silver=>$s, copper=>$c);
        if (!_strict_trade_check($opt, $offered_ref, \%required, \%coins_offered)) {
            _dbg($opt, "REJECT normal: strict_trade failed (extra items/coins)");
            return wantarray ? (0,0) : 0;
        }
    }

    _dbg($opt, "CALL CheckHandin normal");

    if ($npc->CheckHandin($client, $offered_ref, \%required, @item_insts)) {
        _dbg($opt, "SUCCESS normal handin");
        return wantarray ? (1, 0) : 1;
    }

    _dbg($opt, "FAIL normal handin");
    return wantarray ? (0,0) : 0;
}

# ================================================================
# plugin::return_items(\%itemcount)
# Uses engine return to prevent stack/dupe issues.
# ================================================================
sub return_items {
    my $hashref = shift; # kept for compatibility; engine return ignores it

    my $client = plugin::val('client');
    my $npc    = plugin::val('npc');

    return 0 if !$client || !$npc;

    $npc->ReturnHandinItems($client);
    return 1;
}

1;

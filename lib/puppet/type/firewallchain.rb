# This is a workaround for bug: #4248 whereby ruby files outside of the normal
# provider/type path do not load until pluginsync has occured on the puppetmaster
#
# In this case I'm trying the relative path first, then falling back to normal
# mechanisms. This should be fixed in future versions of puppet but it looks
# like we'll need to maintain this for some time perhaps.
$LOAD_PATH.unshift(File.join(File.dirname(__FILE__),"..",".."))
require 'puppet/util/firewall'

Puppet::Type.newtype(:firewallchain) do
  include Puppet::Util::Firewall

  @doc = <<-EOS
    This type provides the capability to manage rule chains for firewalls.

    Currently this supports only iptables, ip6tables and ebtables on Linux. And
    provides support for setting the default policy on chains and tables that
    allow it.

    **Autorequires:**
    If Puppet is managing the iptables or iptables-persistent packages, and
    the provider is iptables_chain, the firewall resource will autorequire
    those packages to ensure that any required binaries are installed.
  EOS

  feature :iptables_chain, "The provider provides iptables chain features."
  feature :policy, "Default policy (inbuilt chains only)"

  ensurable do
    defaultvalues
    defaultto :present
  end

  newparam(:name) do
    desc <<-EOS
      The canonical name of the chain.

      For iptables the format must be {chain}:{table}:{protocol}.
    EOS
    isnamevar

    validate do |value|
      if value !~ Nameformat then
        raise ArgumentError, "Inbuilt chains must be in the form {chain}:{table}:{protocol} where {table} is one of FILTER, NAT, MANGLE, RAW, RAWPOST, BROUTE or empty (alias for filter), chain can be anything without colons or one of PREROUTING, POSTROUTING, BROUTING, INPUT, FORWARD, OUTPUT for the inbuilt chains, and {protocol} being IPv4, IPv6, ethernet (ethernet bridging) got '#{value}' table:'#{$1}' chain:'#{$2}' protocol:'#{$3}'"
      else
        chain = $1
        table = $2
        protocol = $3
        case table
        when 'filter'
          if chain =~ /^(PREROUTING|POSTROUTING|BROUTING)$/
            raise ArgumentError, "INPUT, OUTPUT and FORWARD are the only inbuilt chains that can be used in table 'filter'"
          end
        when 'mangle'
          if chain =~ InternalChains && chain == 'BROUTING'
            raise ArgumentError, "PREROUTING, POSTROUTING, INPUT, FORWARD and OUTPUT are the only inbuilt chains that can be used in table 'mangle'"
          end
        when 'nat'
          if chain =~ /^(BROUTING|INPUT|FORWARD)$/
            raise ArgumentError, "PREROUTING, POSTROUTING and OUTPUT are the only inbuilt chains that can be used in table 'nat'"
          end
          if protocol =~/^(IP(v6)?)?$/
            raise ArgumentError, "table nat isn't valid in IPv6. You must specify ':IPv4' as the name suffix"
          end
        when 'raw'
          if chain =~ /^(POSTROUTING|BROUTING|INPUT|FORWARD)$/
            raise ArgumentError,'PREROUTING and OUTPUT are the only inbuilt chains in the table \'raw\''
          end
        when 'broute'
          if protocol != 'ethernet'
            raise ArgumentError,'BROUTE is only valid with protocol \'ethernet\''
          end
          if chain =~ /^PREROUTING|POSTROUTING|INPUT|FORWARD|OUTPUT$/
            raise ArgumentError,'BROUTING is the only inbuilt chain allowed on on table \'broute\''
          end
        end
        if chain == 'BROUTING' && ( protocol != 'ethernet' || table!='broute')
          raise ArgumentError,'BROUTING is the only inbuilt chain allowed on on table \'BROUTE\' with protocol \'ethernet\' i.e. \'broute:BROUTING:enternet\''
        end
      end
    end
  end

  newproperty(:policy) do
    desc <<-EOS
      This is the action to when the end of the chain is reached.
      It can only be set on inbuilt chains (INPUT, FORWARD, OUTPUT,
      PREROUTING, POSTROUTING) and can be one of:

      * accept - the packet is accepted
      * drop - the packet is dropped
      * queue - the packet is passed userspace
      * return - the packet is returned to calling (jump) queue
                 or the default of inbuilt chains
    EOS
    newvalues(:accept, :drop, :queue, :return)
    defaultto do
      # ethernet chain have an ACCEPT default while other haven't got an
      # allowed value
      if @resource[:name] =~ /:ethernet$/
        :accept
      else
        nil
      end
    end
  end

  # Classes would be a better abstraction, pending:
  # http://projects.puppetlabs.com/issues/19001
  autorequire(:package) do
    case value(:provider)
    when :iptables_chain
      %w{iptables iptables-persistent}
    else
      []
    end
  end

  validate do
    debug("[validate]")

    value(:name).match(Nameformat)
    chain = $1
    table = $2
    protocol = $3

    # Check that we're not removing an internal chain
    if chain =~ InternalChains && value(:ensure) == :absent
      self.fail "Cannot remove in-built chains"
    end

    if value(:policy).nil? && protocol == 'ethernet'
      self.fail "you must set a non-empty policy on all ethernet table chains"
    end

    # Check that we're not setting a policy on a user chain
    if chain !~ InternalChains &&
      !value(:policy).nil? &&
      protocol != 'ethernet'

      self.fail "policy can only be set on in-built chains (with the exception of ethernet chains) (table:#{table} chain:#{chain} protocol:#{protocol})"
    end

    # no DROP policy on nat table
    if table == 'nat' &&
      value(:policy) == :drop

      self.fail 'The "nat" table is not intended for filtering, the use of DROP is therefore inhibited'
    end
  end
end

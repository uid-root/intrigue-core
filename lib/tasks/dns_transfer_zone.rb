module Intrigue
module Task
class DnsTransferZone < BaseTask

  def self.metadata
    {
      :name => "dns_transfer_zone",
      :pretty_name => "DNS Zone Transfer",
      :authors => ["jcran"],
      :description => "DNS Zone Transfer",
      :references => [],
      :allowed_types => ["Domain","DnsRecord"],
      :type => "discovery",
      :passive => false,
      :example_entities => [
        {"type" => "Domain", "details" => {"name" => "intrigue.io"}}
      ],
      :allowed_options => [ ],
      :created_types => ["DnsRecord"]
    }
  end

  def run
    super

    domain_name = _get_entity_name

    # Get the nameservers
    authoritative_nameservers = []
    Resolv::DNS.open do |dns|
      resources = dns.getresources(domain_name, Resolv::DNS::Resource::IN::NS)
      resources.each do |r|
        dns.each_resource(r.name, Resolv::DNS::Resource::IN::A){ |x| authoritative_nameservers << x.address.to_s }
      end
    end

    # For each authoritive nameserver
    authoritative_nameservers.each do |nameserver|
      begin

        _log "Attempting Zone Transfer on #{domain_name} against nameserver #{nameserver}"

        # Do the actual zone transfer
        zt = Dnsruby::ZoneTransfer.new
        zt.transfer_type = Dnsruby::Types.AXFR
        zt.server = nameserver
        zone = zt.transfer(domain_name)

        # create an issue to track this
        _create_issue({
          name: "DNS Zone (AXFR) Transfer Enabled",
          type: "dns_zone_transfer",
          severity: 4,
          status: "confirmed",
          description: "Zone transfer on #{domain_name} using #{nameserver} resulted in leak of #{zone.count} records.",
          details: { records: zone.map{|r| r.name.to_s } }
        })

        # Create records for each item in the zone
        zone.each do |z|
          if z.type.to_s == "SOA"
            _create_entity "Domain", { "name" => z.name.to_s, "record_type" => z.type.to_s, "record_content" => "#{z.to_s}" }
          else

            # Check to see what type this record's content is.
            # MX records are of form: [10, #<Dnsruby::Name: vv-cephei.ac-grenoble.fr.>
            z.rdata.respond_to?("last") ? record = "#{z.rdata.last.to_s}" : record = "#{z.rdata.to_s}"

            sanitized_record = record.sanitize_unicode

            # only create DNS records
            next if record.is_ip_address? 

            # ensure it is a valid address & check for base64 records
            next if sanitized_record =~ /^.*==$/

            # create it
            _create_entity "DnsRecord", { "name" => "#{sanitized_record.strip}", "record_type" => "#{z.type.to_s}", "record_content" => "#{sanitized_record.strip}" }

          end
        end

      rescue Dnsruby::Refused => e
        _log "Zone Transfer against #{domain_name} refused: #{e}"
      rescue Dnsruby::ResolvError => e
        _log "Unable to resolve #{domain_name} while querying #{nameserver}: #{e}"
      rescue Dnsruby::ResolvTimeout =>  e
        _log "Timed out while querying #{nameserver} for #{domain_name}: #{e}"
      rescue Errno::EHOSTUNREACH => e
        _log_error "Unable to connect: (#{e})"
      rescue Errno::ECONNREFUSED => e
        _log_error "Unable to connect: (#{e})"
      rescue Errno::ECONNRESET => e
        _log_error "Unable to connect: (#{e})"
      rescue Errno::EPIPE => e
        _log_error "Unable to connect: (#{e})"
      rescue Errno::ETIMEDOUT => e
        _log_error "Unable to connect: (#{e})"
      end # end begin
    end # end .each
  end # end run

end
end
end

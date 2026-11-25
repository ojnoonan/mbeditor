# frozen_string_literal: true

require "zlib"

module Mbeditor
  # Minimal ZIP on stdlib: deflated entries, no ZIP64, no encryption. Anything
  # past the 4 GB / 65535-entry limits of the plain format is refused.
  module ZipWriter
    LIMIT = 0xFFFFFFFF
    DOS_DATE = (1 << 5) | 1 # 1980-01-01; a bundle's content, not its mtime, is the point
    UTF8_NAMES = 0x0800
    DEFLATED = 8

    # +entries+ is [[name, data], ...]. Returns the archive as a binary String.
    def self.write(entries)
      raise ArgumentError, "too many entries" if entries.length > 0xFFFF

      out = String.new(encoding: Encoding::BINARY)
      central = String.new(encoding: Encoding::BINARY)
      entries.each do |name, data|
        name = name.b
        data = data.b
        z = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS)
        packed = z.deflate(data, Zlib::FINISH)
        z.close
        crc = Zlib.crc32(data)
        offset = out.bytesize
        out << [0x04034b50, 20, UTF8_NAMES, DEFLATED, 0, DOS_DATE, crc, packed.bytesize, data.bytesize, name.bytesize, 0].pack("Vv5V3v2") << name << packed
        central << [0x02014b50, 20, 20, UTF8_NAMES, DEFLATED, 0, DOS_DATE, crc, packed.bytesize, data.bytesize,
                    name.bytesize, 0, 0, 0, 0, 0, offset].pack("Vv6V3v5V2") << name
        raise ArgumentError, "archive over 4 GB" if out.bytesize > LIMIT
      end
      raise ArgumentError, "archive over 4 GB" if out.bytesize + central.bytesize > LIMIT

      central_offset = out.bytesize
      out << central << [0x06054b50, 0, 0, entries.length, entries.length, central.bytesize, central_offset, 0].pack("Vv4V2v")
    end
  end
end

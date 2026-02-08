module Stitch
  module Validations
    struct Result(T)
      protected property errors : Array(Error) { [] of Error }

      def validate_presence(**values) : self
        values.each do |name, value|
          validate name.to_s, "must not be blank" { value.presence }
        end

        self
      end

      def validate_format(format : Regex, **attributes) : self
        attributes.each do |attr, value|
          validate_format attr.to_s, value, format, failure_message: "is in the wrong format"
        end

        self
      end

      def validate_format(value : String, format : Regex, *, failure_message : String) : self
        validate_format nil, value, format, failure_message: failure_message
      end

      def validate_format(name, value : String, format : Regex, *, failure_message : String = "is in the wrong format") : self
        validate name.to_s, failure_message do
          value =~ format
        end
      end

      def validate_size(name : String, value, size : Range, unit : String, *, failure_message = default_validate_size_failure_message(size, unit)) : self
        validate name, failure_message do
          size.includes? value.size
        end
      end

      private def default_validate_size_failure_message(size : Range, unit : String)
        case size
        when .finite?
          if (min = size.begin) && (max = size.end)
            r = Range.new(min, max, size.excludes_end?)
            range = "#{r.min}-#{r.max}"
          else
            raise "bug"
          end
        when .begin
          if min = size.begin
            range = "at least #{min}"
          else
            raise "bug"
          end
        when .end
          if (max = size.end)
            r = Range.new(max - 1, max, size.excludes_end?)
            range = "at most #{r.max}"
          else
            raise "bug"
          end
        end
        failure_message = "must be #{range} #{unit}"
      end

      def validate_uniqueness(attribute, &) : self
        validate attribute, "has already been taken" do
          !yield
        end
      end

      def validate_uniqueness(*, message : String, &) : self
        validate "", message do
          !yield
        end
      end

      def validate(message : String, &)
        validate "", message do
          yield
        end
      end

      def validate(attribute : String, message : String, &)
        unless yield
          errors << Error.new(attribute, message)
        end

        self
      end

      def |(other : Result)
        result = self.class.new
        result.errors = errors | other.errors
        result
      end

      def valid(&) : T | Failure
        if errors.empty?
          yield
        else
          Failure.new(errors.sort_by(&.attribute))
        end
      end
    end

    record Error, attribute : String, message : String do
      def to_s(io : IO)
        unless attribute.empty?
          io << attribute << ' '
        end

        io << message
      end

      def ==(value : String)
        to_s == value
      end
    end

    record Failure, errors : Array(Error) do
      def self.new(error_messages : Array(String)) : Failure
        new error_messages.map { |message| Error.new("", message) }
      end
    end
  end
end

struct Range
  def finite?
    !!(self.begin && self.end)
  end
end

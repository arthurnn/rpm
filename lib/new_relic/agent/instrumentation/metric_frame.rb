# encoding: utf-8
# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/rpm/blob/master/LICENSE for complete details.

# This is a legacy support shim now that the MetricFrame functionality has
# moved over to the Transaction class instead.
#
# This class is deprecated and will be removed in a future agent version.
#
# This class is not part of the public API.  Avoid making calls on it directly.
#
module NewRelic
  module Agent
    module Instrumentation
      class MetricFrame

        def self.recording_web_transaction?
          Transaction.recording_web_transaction?
        end

        def self.abort_transaction!
          Transaction.abort_transaction!
        end

      end
    end
  end
end

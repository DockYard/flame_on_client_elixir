Mox.defmock(FlameOn.Client.Shipper.MockAdapter, for: FlameOn.Client.Shipper.Behaviour)
Mox.defmock(FlameOn.Client.ErrorShipper.MockAdapter, for: FlameOn.Client.ErrorShipper.Behaviour)

# Initialize Phase 2 safety mechanisms globally for tests.
# These use persistent_term and ETS tables which are global singletons.
FlameOn.Client.CircuitBreaker.init()
FlameOn.Client.TraceDedupe.init()
FlameOn.Client.FinalizationGate.init(2)

ExUnit.start()

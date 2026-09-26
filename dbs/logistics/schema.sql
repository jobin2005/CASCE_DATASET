-- =====================================================================
-- Logistics Database Schema (PostgreSQL 14+)
-- Covers: clients, facilities, fleet & drivers, shipments & packages,
--         routing & trips, tracking, proof of delivery, rating & invoicing
-- =====================================================================

BEGIN;

CREATE SCHEMA IF NOT EXISTS logistics;
SET search_path TO logistics;

-- ---------------------------------------------------------------------
-- Enumerated types
-- ---------------------------------------------------------------------
CREATE TYPE facility_type    AS ENUM ('warehouse', 'hub', 'depot', 'cross_dock', 'port', 'airport', 'customer_site');
CREATE TYPE vehicle_type     AS ENUM ('van', 'box_truck', 'tractor', 'trailer', 'reefer', 'motorbike', 'container');
CREATE TYPE vehicle_status   AS ENUM ('available', 'in_service', 'maintenance', 'out_of_service', 'retired');
CREATE TYPE shipment_status  AS ENUM ('booked', 'awaiting_pickup', 'picked_up', 'at_hub', 'in_transit', 'out_for_delivery', 'delivered', 'failed_attempt', 'on_hold', 'returned_to_sender', 'cancelled');
CREATE TYPE service_level    AS ENUM ('same_day', 'next_day', 'express', 'standard', 'economy', 'freight');
CREATE TYPE trip_status      AS ENUM ('planned', 'dispatched', 'in_progress', 'completed', 'cancelled');
CREATE TYPE stop_type        AS ENUM ('pickup', 'delivery', 'transfer', 'fuel', 'rest');
CREATE TYPE invoice_status   AS ENUM ('draft', 'issued', 'paid', 'overdue', 'void');

CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------
-- Clients & contacts
-- ---------------------------------------------------------------------
CREATE TABLE clients (
    client_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_code    VARCHAR(20) UNIQUE NOT NULL,
    legal_name      VARCHAR(255) NOT NULL,
    tax_id          VARCHAR(50),
    billing_email   VARCHAR(255),
    phone           VARCHAR(30),
    payment_terms_days SMALLINT NOT NULL DEFAULT 30,
    credit_limit    NUMERIC(14,2),
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE locations (
    location_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    client_id       BIGINT REFERENCES clients(client_id),   -- NULL for company-owned facilities
    name            VARCHAR(200) NOT NULL,
    facility_type   facility_type NOT NULL,
    code            VARCHAR(20) UNIQUE,              -- e.g. hub code, UN/LOCODE
    line1           VARCHAR(200) NOT NULL,
    line2           VARCHAR(200),
    city            VARCHAR(100) NOT NULL,
    state           VARCHAR(100),
    postal_code     VARCHAR(20),
    country         CHAR(2) NOT NULL,
    latitude        NUMERIC(9,6),
    longitude       NUMERIC(9,6),
    timezone        VARCHAR(50) NOT NULL DEFAULT 'UTC',
    contact_name    VARCHAR(150),
    contact_phone   VARCHAR(30),
    opening_hours   JSONB,                           -- {"mon":"08:00-18:00", ...}
    dock_count      SMALLINT,
    CHECK (latitude  BETWEEN -90  AND 90),
    CHECK (longitude BETWEEN -180 AND 180)
);
CREATE INDEX idx_locations_client ON locations (client_id);
CREATE INDEX idx_locations_geo    ON locations (latitude, longitude);

-- ---------------------------------------------------------------------
-- Carriers, fleet & drivers
-- ---------------------------------------------------------------------
CREATE TABLE carriers (
    carrier_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name            VARCHAR(200) NOT NULL,
    scac_code       CHAR(4) UNIQUE,                  -- Standard Carrier Alpha Code
    is_own_fleet    BOOLEAN NOT NULL DEFAULT FALSE,
    insurance_expiry DATE,
    rating          NUMERIC(3,2) CHECK (rating BETWEEN 0 AND 5)
);

CREATE TABLE vehicles (
    vehicle_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    carrier_id      BIGINT NOT NULL REFERENCES carriers(carrier_id),
    home_location_id BIGINT REFERENCES locations(location_id),
    registration_no VARCHAR(20) UNIQUE NOT NULL,
    vin             VARCHAR(17) UNIQUE,
    vehicle_type    vehicle_type NOT NULL,
    make            VARCHAR(50),
    model           VARCHAR(50),
    year            SMALLINT,
    max_weight_kg   NUMERIC(10,2) NOT NULL,
    max_volume_m3   NUMERIC(8,2) NOT NULL,
    is_refrigerated BOOLEAN NOT NULL DEFAULT FALSE,
    hazmat_certified BOOLEAN NOT NULL DEFAULT FALSE,
    status          vehicle_status NOT NULL DEFAULT 'available',
    odometer_km     INTEGER NOT NULL DEFAULT 0,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE vehicle_maintenance (
    maintenance_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vehicle_id      BIGINT NOT NULL REFERENCES vehicles(vehicle_id) ON DELETE CASCADE,
    maintenance_type VARCHAR(50) NOT NULL,           -- oil_change, tyre, inspection, repair
    description     TEXT,
    odometer_km     INTEGER,
    cost            NUMERIC(10,2),
    performed_at    DATE NOT NULL,
    next_due_date   DATE,
    next_due_km     INTEGER
);

CREATE TABLE drivers (
    driver_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    carrier_id      BIGINT NOT NULL REFERENCES carriers(carrier_id),
    employee_code   VARCHAR(20) UNIQUE,
    full_name       VARCHAR(200) NOT NULL,
    phone           VARCHAR(30) NOT NULL,
    license_number  VARCHAR(50) UNIQUE NOT NULL,
    license_class   VARCHAR(10) NOT NULL,
    license_expiry  DATE NOT NULL,
    hazmat_endorsed BOOLEAN NOT NULL DEFAULT FALSE,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    hired_on        DATE
);

-- ---------------------------------------------------------------------
-- Shipments & packages
-- ---------------------------------------------------------------------
CREATE TABLE shipments (
    shipment_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tracking_number     VARCHAR(30) UNIQUE NOT NULL,
    client_id           BIGINT NOT NULL REFERENCES clients(client_id),
    client_reference    VARCHAR(100),                -- client's PO / order number
    origin_location_id  BIGINT NOT NULL REFERENCES locations(location_id),
    destination_location_id BIGINT NOT NULL REFERENCES locations(location_id),
    service_level       service_level NOT NULL DEFAULT 'standard',
    status              shipment_status NOT NULL DEFAULT 'booked',
    incoterm            CHAR(3),                     -- EXW, FOB, DDP ...
    declared_value      NUMERIC(14,2),
    currency_code       CHAR(3) NOT NULL DEFAULT 'USD',
    total_weight_kg     NUMERIC(10,2),
    total_volume_m3     NUMERIC(8,3),
    is_hazardous        BOOLEAN NOT NULL DEFAULT FALSE,
    requires_signature  BOOLEAN NOT NULL DEFAULT FALSE,
    temperature_min_c   NUMERIC(4,1),
    temperature_max_c   NUMERIC(4,1),
    pickup_window_start TIMESTAMPTZ,
    pickup_window_end   TIMESTAMPTZ,
    promised_delivery_at TIMESTAMPTZ,
    delivered_at        TIMESTAMPTZ,
    special_instructions TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (origin_location_id <> destination_location_id),
    CHECK (pickup_window_end IS NULL OR pickup_window_end > pickup_window_start)
);
CREATE INDEX idx_shipments_client  ON shipments (client_id, created_at DESC);
CREATE INDEX idx_shipments_status  ON shipments (status);
CREATE INDEX idx_shipments_promise ON shipments (promised_delivery_at) WHERE delivered_at IS NULL;

CREATE TABLE packages (
    package_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    shipment_id     BIGINT NOT NULL REFERENCES shipments(shipment_id) ON DELETE CASCADE,
    barcode         VARCHAR(50) UNIQUE NOT NULL,     -- SSCC or internal label
    package_type    VARCHAR(20) NOT NULL CHECK (package_type IN ('envelope','parcel','pallet','crate','drum','container')),
    weight_kg       NUMERIC(10,2) NOT NULL CHECK (weight_kg > 0),
    length_cm       NUMERIC(7,1),
    width_cm        NUMERIC(7,1),
    height_cm       NUMERIC(7,1),
    description     VARCHAR(255),
    hs_code         VARCHAR(12),                     -- customs tariff code
    un_number       CHAR(6),                         -- dangerous goods
    current_location_id BIGINT REFERENCES locations(location_id)
);
CREATE INDEX idx_packages_shipment ON packages (shipment_id);

-- ---------------------------------------------------------------------
-- Routing & trips (a trip = one vehicle run with ordered stops)
-- ---------------------------------------------------------------------
CREATE TABLE routes (
    route_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code            VARCHAR(30) UNIQUE NOT NULL,
    name            VARCHAR(150) NOT NULL,
    origin_location_id      BIGINT NOT NULL REFERENCES locations(location_id),
    destination_location_id BIGINT NOT NULL REFERENCES locations(location_id),
    distance_km     NUMERIC(8,1),
    standard_duration_min INTEGER,
    is_recurring    BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE trips (
    trip_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    trip_number     VARCHAR(30) UNIQUE NOT NULL,
    route_id        BIGINT REFERENCES routes(route_id),
    vehicle_id      BIGINT NOT NULL REFERENCES vehicles(vehicle_id),
    trailer_id      BIGINT REFERENCES vehicles(vehicle_id),
    driver_id       BIGINT NOT NULL REFERENCES drivers(driver_id),
    co_driver_id    BIGINT REFERENCES drivers(driver_id),
    status          trip_status NOT NULL DEFAULT 'planned',
    planned_start   TIMESTAMPTZ NOT NULL,
    planned_end     TIMESTAMPTZ,
    actual_start    TIMESTAMPTZ,
    actual_end      TIMESTAMPTZ,
    start_odometer_km INTEGER,
    end_odometer_km INTEGER,
    fuel_used_l     NUMERIC(8,2),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (co_driver_id IS NULL OR co_driver_id <> driver_id)
);
CREATE INDEX idx_trips_vehicle ON trips (vehicle_id, planned_start);
CREATE INDEX idx_trips_driver  ON trips (driver_id, planned_start);

CREATE TABLE trip_stops (
    stop_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    trip_id         BIGINT NOT NULL REFERENCES trips(trip_id) ON DELETE CASCADE,
    sequence_no     SMALLINT NOT NULL,
    location_id     BIGINT NOT NULL REFERENCES locations(location_id),
    stop_type       stop_type NOT NULL,
    planned_arrival TIMESTAMPTZ,
    actual_arrival  TIMESTAMPTZ,
    actual_departure TIMESTAMPTZ,
    notes           TEXT,
    UNIQUE (trip_id, sequence_no)
);

-- Which packages ride on which trip leg (supports multi-leg / hub-and-spoke)
CREATE TABLE trip_packages (
    trip_id         BIGINT NOT NULL REFERENCES trips(trip_id) ON DELETE CASCADE,
    package_id      BIGINT NOT NULL REFERENCES packages(package_id),
    load_stop_id    BIGINT NOT NULL REFERENCES trip_stops(stop_id),
    unload_stop_id  BIGINT NOT NULL REFERENCES trip_stops(stop_id),
    loaded_at       TIMESTAMPTZ,
    unloaded_at     TIMESTAMPTZ,
    PRIMARY KEY (trip_id, package_id)
);
CREATE INDEX idx_trip_packages_package ON trip_packages (package_id);

-- ---------------------------------------------------------------------
-- Tracking & telemetry
-- ---------------------------------------------------------------------
CREATE TABLE tracking_events (
    event_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    shipment_id     BIGINT NOT NULL REFERENCES shipments(shipment_id) ON DELETE CASCADE,
    package_id      BIGINT REFERENCES packages(package_id),
    event_code      VARCHAR(30) NOT NULL,            -- SCANNED_IN, DEPARTED, ARRIVED, EXCEPTION...
    status          shipment_status,
    location_id     BIGINT REFERENCES locations(location_id),
    trip_id         BIGINT REFERENCES trips(trip_id),
    description     VARCHAR(255),
    exception_reason VARCHAR(100),
    source          VARCHAR(20) NOT NULL DEFAULT 'scanner' CHECK (source IN ('scanner','driver_app','edi','api','manual')),
    occurred_at     TIMESTAMPTZ NOT NULL,
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_tracking_shipment ON tracking_events (shipment_id, occurred_at DESC);

CREATE TABLE vehicle_positions (
    vehicle_id      BIGINT NOT NULL REFERENCES vehicles(vehicle_id),
    recorded_at     TIMESTAMPTZ NOT NULL,
    latitude        NUMERIC(9,6) NOT NULL,
    longitude       NUMERIC(9,6) NOT NULL,
    speed_kmh       NUMERIC(5,1),
    heading_deg     SMALLINT CHECK (heading_deg BETWEEN 0 AND 359),
    reefer_temp_c   NUMERIC(4,1),
    trip_id         BIGINT REFERENCES trips(trip_id),
    PRIMARY KEY (vehicle_id, recorded_at)
);   -- high volume: consider partitioning by recorded_at

CREATE TABLE proof_of_delivery (
    pod_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    shipment_id     BIGINT NOT NULL REFERENCES shipments(shipment_id),
    driver_id       BIGINT REFERENCES drivers(driver_id),
    recipient_name  VARCHAR(200) NOT NULL,
    signature_uri   TEXT,
    photo_uri       TEXT,
    latitude        NUMERIC(9,6),
    longitude       NUMERIC(9,6),
    delivered_at    TIMESTAMPTZ NOT NULL,
    notes           TEXT
);

-- ---------------------------------------------------------------------
-- Rating & invoicing
-- ---------------------------------------------------------------------
CREATE TABLE rate_cards (
    rate_card_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    client_id       BIGINT REFERENCES clients(client_id),   -- NULL = public tariff
    service_level   service_level NOT NULL,
    origin_zone     VARCHAR(20) NOT NULL,
    destination_zone VARCHAR(20) NOT NULL,
    min_weight_kg   NUMERIC(10,2) NOT NULL DEFAULT 0,
    max_weight_kg   NUMERIC(10,2),
    base_charge     NUMERIC(10,2) NOT NULL,
    per_kg_charge   NUMERIC(10,4) NOT NULL DEFAULT 0,
    fuel_surcharge_pct NUMERIC(5,2) NOT NULL DEFAULT 0,
    valid_from      DATE NOT NULL,
    valid_to        DATE
);

CREATE TABLE shipment_charges (
    charge_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    shipment_id     BIGINT NOT NULL REFERENCES shipments(shipment_id) ON DELETE CASCADE,
    charge_type     VARCHAR(30) NOT NULL,            -- freight, fuel, hazmat, residential, detention, customs
    amount          NUMERIC(12,2) NOT NULL,
    rate_card_id    BIGINT REFERENCES rate_cards(rate_card_id),
    invoice_id      BIGINT                           -- FK added below
);

CREATE TABLE invoices (
    invoice_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    invoice_number  VARCHAR(30) UNIQUE NOT NULL,
    client_id       BIGINT NOT NULL REFERENCES clients(client_id),
    status          invoice_status NOT NULL DEFAULT 'draft',
    period_start    DATE,
    period_end      DATE,
    subtotal        NUMERIC(14,2) NOT NULL DEFAULT 0,
    tax_total       NUMERIC(14,2) NOT NULL DEFAULT 0,
    grand_total     NUMERIC(14,2) NOT NULL DEFAULT 0,
    currency_code   CHAR(3) NOT NULL DEFAULT 'USD',
    issued_on       DATE,
    due_on          DATE,
    paid_on         DATE
);

ALTER TABLE shipment_charges
    ADD CONSTRAINT fk_charges_invoice FOREIGN KEY (invoice_id) REFERENCES invoices(invoice_id);
CREATE INDEX idx_charges_uninvoiced ON shipment_charges (shipment_id) WHERE invoice_id IS NULL;

-- ---------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_clients_updated   BEFORE UPDATE ON clients   FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_vehicles_updated  BEFORE UPDATE ON vehicles  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_shipments_updated BEFORE UPDATE ON shipments FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_trips_updated     BEFORE UPDATE ON trips     FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Latest known status per shipment
CREATE VIEW v_shipment_latest_event AS
SELECT DISTINCT ON (shipment_id)
       shipment_id, event_code, status, location_id, occurred_at
FROM tracking_events
ORDER BY shipment_id, occurred_at DESC;

COMMIT;
-- =====================================================================
-- E-commerce Database Schema (PostgreSQL 14+)
-- Covers: customers, catalog & variants, inventory, carts, orders,
--         payments, shipments, returns, promotions, reviews
-- =====================================================================

BEGIN;

CREATE SCHEMA IF NOT EXISTS ecommerce;
SET search_path TO ecommerce;

-- ---------------------------------------------------------------------
-- Enumerated types
-- ---------------------------------------------------------------------
CREATE TYPE order_status    AS ENUM ('pending_payment', 'paid', 'processing', 'partially_shipped', 'shipped', 'delivered', 'cancelled', 'refunded');
CREATE TYPE payment_status  AS ENUM ('pending', 'authorized', 'captured', 'failed', 'refunded', 'partially_refunded', 'voided');
CREATE TYPE shipment_status AS ENUM ('label_created', 'picked_up', 'in_transit', 'out_for_delivery', 'delivered', 'exception', 'returned');
CREATE TYPE return_status   AS ENUM ('requested', 'approved', 'rejected', 'received', 'refunded');
CREATE TYPE discount_type   AS ENUM ('percentage', 'fixed_amount', 'free_shipping');
CREATE TYPE product_status  AS ENUM ('draft', 'active', 'archived');

CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------
-- Customers
-- ---------------------------------------------------------------------
CREATE TABLE customers (
    customer_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email           VARCHAR(255) NOT NULL,
    password_hash   VARCHAR(255),                    -- NULL for guest checkouts
    first_name      VARCHAR(100),
    last_name       VARCHAR(100),
    phone           VARCHAR(30),
    is_guest        BOOLEAN NOT NULL DEFAULT FALSE,
    marketing_opt_in BOOLEAN NOT NULL DEFAULT FALSE,
    email_verified_at TIMESTAMPTZ,
    last_login_at   TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_customers_email ON customers (lower(email)) WHERE is_guest = FALSE;

CREATE TABLE addresses (
    address_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id     BIGINT NOT NULL REFERENCES customers(customer_id) ON DELETE CASCADE,
    full_name       VARCHAR(200) NOT NULL,
    line1           VARCHAR(200) NOT NULL,
    line2           VARCHAR(200),
    city            VARCHAR(100) NOT NULL,
    state           VARCHAR(100),
    postal_code     VARCHAR(20) NOT NULL,
    country         CHAR(2) NOT NULL,
    phone           VARCHAR(30),
    is_default_shipping BOOLEAN NOT NULL DEFAULT FALSE,
    is_default_billing  BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE INDEX idx_addresses_customer ON addresses (customer_id);

-- ---------------------------------------------------------------------
-- Catalog
-- ---------------------------------------------------------------------
CREATE TABLE categories (
    category_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    parent_id       BIGINT REFERENCES categories(category_id),
    name            VARCHAR(150) NOT NULL,
    slug            VARCHAR(160) UNIQUE NOT NULL,
    description     TEXT,
    sort_order      INTEGER NOT NULL DEFAULT 0,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE brands (
    brand_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name            VARCHAR(150) UNIQUE NOT NULL,
    slug            VARCHAR(160) UNIQUE NOT NULL,
    logo_url        TEXT
);

CREATE TABLE products (
    product_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    brand_id        BIGINT REFERENCES brands(brand_id),
    name            VARCHAR(255) NOT NULL,
    slug            VARCHAR(270) UNIQUE NOT NULL,
    description     TEXT,
    status          product_status NOT NULL DEFAULT 'draft',
    tax_class       VARCHAR(30) NOT NULL DEFAULT 'standard',
    attributes      JSONB NOT NULL DEFAULT '{}',     -- material, care instructions, etc.
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_products_status ON products (status);
CREATE INDEX idx_products_attrs  ON products USING GIN (attributes);

CREATE TABLE product_categories (
    product_id      BIGINT NOT NULL REFERENCES products(product_id) ON DELETE CASCADE,
    category_id     BIGINT NOT NULL REFERENCES categories(category_id) ON DELETE CASCADE,
    PRIMARY KEY (product_id, category_id)
);

-- Sellable unit (size / colour combination)
CREATE TABLE product_variants (
    variant_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id      BIGINT NOT NULL REFERENCES products(product_id) ON DELETE CASCADE,
    sku             VARCHAR(64) UNIQUE NOT NULL,
    barcode         VARCHAR(64),
    option_values   JSONB NOT NULL DEFAULT '{}',     -- {"size":"M","color":"Blue"}
    price           NUMERIC(12,2) NOT NULL CHECK (price >= 0),
    compare_at_price NUMERIC(12,2) CHECK (compare_at_price >= 0),
    cost_price      NUMERIC(12,2),
    currency_code   CHAR(3) NOT NULL DEFAULT 'USD',
    weight_grams    INTEGER,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_variants_product ON product_variants (product_id);

CREATE TABLE product_images (
    image_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id      BIGINT NOT NULL REFERENCES products(product_id) ON DELETE CASCADE,
    variant_id      BIGINT REFERENCES product_variants(variant_id) ON DELETE CASCADE,
    url             TEXT NOT NULL,
    alt_text        VARCHAR(255),
    position        SMALLINT NOT NULL DEFAULT 0
);

-- ---------------------------------------------------------------------
-- Inventory
-- ---------------------------------------------------------------------
CREATE TABLE warehouses (
    warehouse_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code            VARCHAR(20) UNIQUE NOT NULL,
    name            VARCHAR(150) NOT NULL,
    city            VARCHAR(100),
    country         CHAR(2) NOT NULL,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE inventory (
    variant_id      BIGINT NOT NULL REFERENCES product_variants(variant_id) ON DELETE CASCADE,
    warehouse_id    BIGINT NOT NULL REFERENCES warehouses(warehouse_id),
    quantity_on_hand INTEGER NOT NULL DEFAULT 0 CHECK (quantity_on_hand >= 0),
    quantity_reserved INTEGER NOT NULL DEFAULT 0 CHECK (quantity_reserved >= 0),
    reorder_point   INTEGER NOT NULL DEFAULT 0,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (variant_id, warehouse_id),
    CHECK (quantity_reserved <= quantity_on_hand)
);

CREATE TABLE inventory_movements (
    movement_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    variant_id      BIGINT NOT NULL REFERENCES product_variants(variant_id),
    warehouse_id    BIGINT NOT NULL REFERENCES warehouses(warehouse_id),
    quantity_change INTEGER NOT NULL,
    reason          VARCHAR(30) NOT NULL CHECK (reason IN ('purchase_order','sale','return','adjustment','transfer_in','transfer_out','damaged')),
    reference_id    BIGINT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_inv_movements_variant ON inventory_movements (variant_id, created_at DESC);

-- ---------------------------------------------------------------------
-- Promotions
-- ---------------------------------------------------------------------
CREATE TABLE coupons (
    coupon_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code            VARCHAR(50) UNIQUE NOT NULL,
    description     VARCHAR(255),
    discount_type   discount_type NOT NULL,
    discount_value  NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (discount_value >= 0),
    min_order_amount NUMERIC(12,2) NOT NULL DEFAULT 0,
    max_discount_amount NUMERIC(12,2),
    usage_limit     INTEGER,
    per_customer_limit INTEGER DEFAULT 1,
    times_used      INTEGER NOT NULL DEFAULT 0,
    starts_at       TIMESTAMPTZ NOT NULL,
    expires_at      TIMESTAMPTZ,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    CHECK (discount_type <> 'percentage' OR discount_value <= 100)
);

-- ---------------------------------------------------------------------
-- Carts & wishlists
-- ---------------------------------------------------------------------
CREATE TABLE carts (
    cart_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id     BIGINT REFERENCES customers(customer_id) ON DELETE CASCADE,
    session_token   VARCHAR(128) UNIQUE,             -- anonymous carts
    coupon_id       BIGINT REFERENCES coupons(coupon_id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (customer_id IS NOT NULL OR session_token IS NOT NULL)
);

CREATE TABLE cart_items (
    cart_id         BIGINT NOT NULL REFERENCES carts(cart_id) ON DELETE CASCADE,
    variant_id      BIGINT NOT NULL REFERENCES product_variants(variant_id),
    quantity        INTEGER NOT NULL CHECK (quantity > 0),
    added_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (cart_id, variant_id)
);

CREATE TABLE wishlist_items (
    customer_id     BIGINT NOT NULL REFERENCES customers(customer_id) ON DELETE CASCADE,
    variant_id      BIGINT NOT NULL REFERENCES product_variants(variant_id) ON DELETE CASCADE,
    added_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (customer_id, variant_id)
);

-- ---------------------------------------------------------------------
-- Orders (addresses & prices are snapshotted at purchase time)
-- ---------------------------------------------------------------------
CREATE TABLE orders (
    order_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_number    VARCHAR(20) UNIQUE NOT NULL,
    customer_id     BIGINT NOT NULL REFERENCES customers(customer_id),
    status          order_status NOT NULL DEFAULT 'pending_payment',
    currency_code   CHAR(3) NOT NULL DEFAULT 'USD',
    subtotal        NUMERIC(12,2) NOT NULL CHECK (subtotal >= 0),
    discount_total  NUMERIC(12,2) NOT NULL DEFAULT 0,
    shipping_total  NUMERIC(12,2) NOT NULL DEFAULT 0,
    tax_total       NUMERIC(12,2) NOT NULL DEFAULT 0,
    grand_total     NUMERIC(12,2) NOT NULL CHECK (grand_total >= 0),
    coupon_id       BIGINT REFERENCES coupons(coupon_id),
    shipping_address JSONB NOT NULL,
    billing_address  JSONB NOT NULL,
    shipping_method VARCHAR(50),
    customer_note   TEXT,
    placed_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    cancelled_at    TIMESTAMPTZ,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (grand_total = subtotal - discount_total + shipping_total + tax_total)
);
CREATE INDEX idx_orders_customer ON orders (customer_id, placed_at DESC);
CREATE INDEX idx_orders_status   ON orders (status);

CREATE TABLE order_items (
    order_item_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id        BIGINT NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
    variant_id      BIGINT NOT NULL REFERENCES product_variants(variant_id),
    sku             VARCHAR(64) NOT NULL,            -- snapshot
    product_name    VARCHAR(255) NOT NULL,           -- snapshot
    quantity        INTEGER NOT NULL CHECK (quantity > 0),
    unit_price      NUMERIC(12,2) NOT NULL,
    discount_amount NUMERIC(12,2) NOT NULL DEFAULT 0,
    tax_amount      NUMERIC(12,2) NOT NULL DEFAULT 0,
    line_total      NUMERIC(12,2) NOT NULL
);
CREATE INDEX idx_order_items_order ON order_items (order_id);

CREATE TABLE order_status_history (
    history_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id        BIGINT NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
    from_status     order_status,
    to_status       order_status NOT NULL,
    note            VARCHAR(255),
    changed_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- Payments
-- ---------------------------------------------------------------------
CREATE TABLE payments (
    payment_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id        BIGINT NOT NULL REFERENCES orders(order_id),
    provider        VARCHAR(30) NOT NULL,            -- stripe, paypal, razorpay
    provider_payment_id VARCHAR(100) UNIQUE,
    method          VARCHAR(30) NOT NULL,            -- card, wallet, upi, cod, bank_transfer
    amount          NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    currency_code   CHAR(3) NOT NULL,
    status          payment_status NOT NULL DEFAULT 'pending',
    card_brand      VARCHAR(20),
    card_last4      CHAR(4),
    failure_code    VARCHAR(50),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    captured_at     TIMESTAMPTZ
);
CREATE INDEX idx_payments_order ON payments (order_id);

CREATE TABLE refunds (
    refund_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    payment_id      BIGINT NOT NULL REFERENCES payments(payment_id),
    amount          NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    reason          VARCHAR(255),
    provider_refund_id VARCHAR(100),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- Fulfilment
-- ---------------------------------------------------------------------
CREATE TABLE shipments (
    shipment_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id        BIGINT NOT NULL REFERENCES orders(order_id),
    warehouse_id    BIGINT NOT NULL REFERENCES warehouses(warehouse_id),
    carrier         VARCHAR(50) NOT NULL,
    service_level   VARCHAR(50),
    tracking_number VARCHAR(100),
    status          shipment_status NOT NULL DEFAULT 'label_created',
    shipping_cost   NUMERIC(10,2),
    shipped_at      TIMESTAMPTZ,
    estimated_delivery DATE,
    delivered_at    TIMESTAMPTZ
);
CREATE INDEX idx_shipments_order ON shipments (order_id);

CREATE TABLE shipment_items (
    shipment_id     BIGINT NOT NULL REFERENCES shipments(shipment_id) ON DELETE CASCADE,
    order_item_id   BIGINT NOT NULL REFERENCES order_items(order_item_id),
    quantity        INTEGER NOT NULL CHECK (quantity > 0),
    PRIMARY KEY (shipment_id, order_item_id)
);

CREATE TABLE returns (
    return_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rma_number      VARCHAR(20) UNIQUE NOT NULL,
    order_id        BIGINT NOT NULL REFERENCES orders(order_id),
    status          return_status NOT NULL DEFAULT 'requested',
    reason          VARCHAR(50) NOT NULL,            -- damaged, wrong_item, not_as_described, changed_mind
    customer_comment TEXT,
    refund_id       BIGINT REFERENCES refunds(refund_id),
    requested_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    received_at     TIMESTAMPTZ
);

CREATE TABLE return_items (
    return_id       BIGINT NOT NULL REFERENCES returns(return_id) ON DELETE CASCADE,
    order_item_id   BIGINT NOT NULL REFERENCES order_items(order_item_id),
    quantity        INTEGER NOT NULL CHECK (quantity > 0),
    condition       VARCHAR(20) CHECK (condition IN ('new','opened','damaged')),
    restock         BOOLEAN NOT NULL DEFAULT TRUE,
    PRIMARY KEY (return_id, order_item_id)
);

-- ---------------------------------------------------------------------
-- Reviews
-- ---------------------------------------------------------------------
CREATE TABLE reviews (
    review_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id      BIGINT NOT NULL REFERENCES products(product_id) ON DELETE CASCADE,
    customer_id     BIGINT NOT NULL REFERENCES customers(customer_id),
    order_item_id   BIGINT REFERENCES order_items(order_item_id),  -- verified purchase
    rating          SMALLINT NOT NULL CHECK (rating BETWEEN 1 AND 5),
    title           VARCHAR(200),
    body            TEXT,
    is_approved     BOOLEAN NOT NULL DEFAULT FALSE,
    helpful_count   INTEGER NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (product_id, customer_id)
);
CREATE INDEX idx_reviews_product ON reviews (product_id) WHERE is_approved;

-- ---------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_customers_updated BEFORE UPDATE ON customers        FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_products_updated  BEFORE UPDATE ON products         FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_variants_updated  BEFORE UPDATE ON product_variants FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_carts_updated     BEFORE UPDATE ON carts            FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_orders_updated    BEFORE UPDATE ON orders           FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_inventory_updated BEFORE UPDATE ON inventory        FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Handy view: sellable stock per variant
CREATE VIEW v_available_stock AS
SELECT variant_id,
       SUM(quantity_on_hand - quantity_reserved) AS available_qty
FROM inventory
GROUP BY variant_id;

COMMIT;
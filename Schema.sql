-- Subscription Billing & Revenue Management System
-- Final Merged Schema

CREATE DATABASE IF NOT EXISTS subscription_billing;
USE subscription_billing;

SET FOREIGN_KEY_CHECKS = 0;

-- 1. USER
CREATE TABLE user (
    user_id        BIGINT          PRIMARY KEY AUTO_INCREMENT,
    full_name      VARCHAR(100)    NOT NULL,
    email          VARCHAR(120)    NOT NULL UNIQUE,
    password_hash  VARCHAR(255)    NULL,                     -- NULL = OAuth2 user
    role           ENUM('CUSTOMER','SUPPORT','FINANCE','ADMIN') NOT NULL DEFAULT 'CUSTOMER',
    status         ENUM('ACTIVE','INACTIVE','SUSPENDED') NOT NULL DEFAULT 'ACTIVE',
    created_at     TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at     TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

-- Seed initial portal staff at deployment (Password for all: password)
INSERT INTO user (full_name, email, password_hash, role, status)
VALUES 
('System Admin', 'admin@streamflix.com', '$2a$10$dXJ3SW6G7P50lGmMkkmwe.20cQQubK3.HCGKKPTBaVR1M//8/2YfO', 'ADMIN', 'ACTIVE'),
('Finance Lead', 'finance@streamflix.com', '$2a$10$dXJ3SW6G7P50lGmMkkmwe.20cQQubK3.HCGKKPTBaVR1M//8/2YfO', 'FINANCE', 'ACTIVE'),
('Support Lead', 'support@streamflix.com', '$2a$10$dXJ3SW6G7P50lGmMkkmwe.20cQQubK3.HCGKKPTBaVR1M//8/2YfO', 'SUPPORT', 'ACTIVE');

-- 2. CUSTOMER
CREATE TABLE customer (
    customer_id      BIGINT          PRIMARY KEY AUTO_INCREMENT,
    user_id          BIGINT          NOT NULL UNIQUE,         -- 1:1 link to User
    phone            VARCHAR(20)     NULL,
    currency         CHAR(3)         NOT NULL,                -- ISO-4217: INR, USD, EUR
    country          CHAR(2)         NOT NULL,                -- ISO-3166: IN, US, GB (drives tax lookup)
    state            VARCHAR(100)    NULL,                    -- for GST intra/inter-state
    city             VARCHAR(100)    NULL,
    address_line1    VARCHAR(255)    NULL,
    postal_code      VARCHAR(20)     NULL,
    status           ENUM('ACTIVE','INACTIVE','SUSPENDED') NOT NULL DEFAULT 'ACTIVE',
    created_at       TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at       TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    FOREIGN KEY (user_id) REFERENCES user(user_id)
);

-- 3. PRODUCT
CREATE TABLE product (
    product_id       BIGINT          PRIMARY KEY AUTO_INCREMENT,
    name             VARCHAR(100)    NOT NULL,
    description      TEXT            NULL,
    status           ENUM('ACTIVE','INACTIVE') NOT NULL DEFAULT 'ACTIVE',
    created_at       TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at       TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

-- 4. PLAN
CREATE TABLE plan (
    plan_id              BIGINT          PRIMARY KEY AUTO_INCREMENT,
    product_id           BIGINT          NOT NULL,
    name                 VARCHAR(100)    NOT NULL,
    billing_period       ENUM('MONTHLY','YEARLY') NOT NULL,
    default_price_minor  BIGINT          NOT NULL,            -- fallback when no PRICE_BOOK_ENTRY matches
    default_currency     CHAR(3)         NOT NULL,
    trial_days           INT             NOT NULL DEFAULT 7,
    setup_fee_minor      BIGINT          NOT NULL DEFAULT 0,
    tax_mode             ENUM('INCLUSIVE','EXCLUSIVE') NOT NULL DEFAULT 'EXCLUSIVE',
    effective_from       DATE            NOT NULL,
    effective_to         DATE            NULL,
    status               ENUM('ACTIVE','INACTIVE') NOT NULL DEFAULT 'ACTIVE',
    created_at           TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at           TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    FOREIGN KEY (product_id) REFERENCES product(product_id)
);

-- 5. PRICE_BOOK_ENTRY
CREATE TABLE price_book_entry (
    price_book_id    BIGINT          PRIMARY KEY AUTO_INCREMENT,
    plan_id          BIGINT          NOT NULL,
    region           VARCHAR(50)     NOT NULL,
    currency         CHAR(3)         NOT NULL,
    price_minor      BIGINT          NOT NULL,
    effective_from   DATE            NOT NULL,
    effective_to     DATE            NULL,

    FOREIGN KEY (plan_id) REFERENCES plan(plan_id),
    UNIQUE (plan_id, region, currency, effective_from)
);

-- 6. ADD_ON
CREATE TABLE add_on (
    add_on_id        BIGINT          PRIMARY KEY AUTO_INCREMENT,
    product_id       BIGINT          NOT NULL,
    name             VARCHAR(100)    NOT NULL,
    price_minor      BIGINT          NOT NULL,
    currency         CHAR(3)         NOT NULL,
    billing_period   ENUM('MONTHLY','YEARLY') NOT NULL,
    tax_mode         ENUM('INCLUSIVE','EXCLUSIVE') NOT NULL DEFAULT 'EXCLUSIVE',
    status           ENUM('ACTIVE','INACTIVE') NOT NULL DEFAULT 'ACTIVE',
    created_at       TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,

    FOREIGN KEY (product_id) REFERENCES product(product_id)
);

-- 7. METERED_COMPONENT
CREATE TABLE metered_component (
    component_id         BIGINT          PRIMARY KEY AUTO_INCREMENT,
    plan_id              BIGINT          NOT NULL,
    name                 VARCHAR(100)    NOT NULL,
    unit_name            VARCHAR(50)     NOT NULL,
    price_per_unit_minor BIGINT          NOT NULL,
    free_tier_quantity   BIGINT          NOT NULL DEFAULT 0,
    status               ENUM('ACTIVE','INACTIVE') NOT NULL DEFAULT 'ACTIVE',
    created_at           TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,

    FOREIGN KEY (plan_id) REFERENCES plan(plan_id)
);

-- 8. SUBSCRIPTION
CREATE TABLE subscription (
    subscription_id       BIGINT          PRIMARY KEY AUTO_INCREMENT,
    customer_id           BIGINT          NOT NULL,
    plan_id               BIGINT          NOT NULL,
    status                ENUM('DRAFT','TRIALING','ACTIVE','PAST_DUE','PAUSED','CANCELED','ON_HOLD') NOT NULL,
    start_date            DATE            NOT NULL,
    trial_end_date        DATE            NULL,
    current_period_start  DATE            NOT NULL,
    current_period_end    DATE            NOT NULL,
    cancel_at_period_end  BOOLEAN         NOT NULL DEFAULT FALSE,
    canceled_at           TIMESTAMP       NULL,
    paused_from           DATE            NULL,
    paused_to             DATE            NULL,
    payment_method_id     BIGINT          NOT NULL,
    currency              CHAR(3)         NOT NULL,
    created_at            TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at            TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    FOREIGN KEY (customer_id) REFERENCES customer(customer_id),
    FOREIGN KEY (plan_id) REFERENCES plan(plan_id),
    FOREIGN KEY (payment_method_id) REFERENCES payment_method(payment_method_id)
);

-- 9. SUBSCRIPTION_ITEM
CREATE TABLE subscription_item (
    item_id              BIGINT          PRIMARY KEY AUTO_INCREMENT,
    subscription_id      BIGINT          NOT NULL,
    item_type            ENUM('PLAN','ADDON','METERED') NOT NULL,
    plan_id              BIGINT          NULL,
    addon_id             BIGINT          NULL,
    component_id         BIGINT          NULL,
    unit_price_minor     BIGINT          NOT NULL,
    quantity             INT             NOT NULL DEFAULT 1,
    tax_mode             ENUM('INCLUSIVE','EXCLUSIVE') NOT NULL DEFAULT 'EXCLUSIVE',
    discount_id          BIGINT          NULL,
    created_at           TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,

    FOREIGN KEY (subscription_id) REFERENCES subscription(subscription_id),
    FOREIGN KEY (plan_id) REFERENCES plan(plan_id),
    FOREIGN KEY (addon_id) REFERENCES add_on(add_on_id),
    FOREIGN KEY (component_id) REFERENCES metered_component(component_id),
    FOREIGN KEY (discount_id) REFERENCES coupon(coupon_id)
);

-- 10. SUBSCRIPTION_COUPON
CREATE TABLE subscription_coupon (
    id                BIGINT          PRIMARY KEY AUTO_INCREMENT,
    subscription_id   BIGINT          NOT NULL,
    coupon_id         BIGINT          NOT NULL,
    applied_at        TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    applied_by        BIGINT          NULL,
    expires_at        TIMESTAMP       NULL,
    status            ENUM('ACTIVE','EXPIRED','REVOKED') NOT NULL DEFAULT 'ACTIVE',

    FOREIGN KEY (subscription_id) REFERENCES subscription(subscription_id),
    FOREIGN KEY (coupon_id) REFERENCES coupon(coupon_id),
    FOREIGN KEY (applied_by) REFERENCES user(user_id),
    UNIQUE (subscription_id, coupon_id)
);

-- 11. USAGE_RECORD
CREATE TABLE usage_record (
    usage_id             BIGINT          PRIMARY KEY AUTO_INCREMENT,
    subscription_id      BIGINT          NOT NULL,
    component_id         BIGINT          NOT NULL,
    quantity             BIGINT          NOT NULL,
    recorded_at          TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    billing_period_start DATE            NOT NULL,
    billing_period_end   DATE            NOT NULL,
    idempotency_key      VARCHAR(100)    NOT NULL UNIQUE,

    FOREIGN KEY (subscription_id) REFERENCES subscription(subscription_id),
    FOREIGN KEY (component_id) REFERENCES metered_component(component_id)
);

-- 12. INVOICE
CREATE TABLE invoice (
    invoice_id        BIGINT          PRIMARY KEY AUTO_INCREMENT,
    invoice_number    VARCHAR(50)     NOT NULL UNIQUE,
    customer_id       BIGINT          NOT NULL,
    subscription_id   BIGINT          NOT NULL,
    status            ENUM('DRAFT','OPEN','PAID','VOID','UNCOLLECTIBLE') NOT NULL,
    billing_reason    ENUM('SUBSCRIPTION_CREATE','SUBSCRIPTION_CYCLE','SUBSCRIPTION_UPDATE','MANUAL') NOT NULL,
    issue_date        DATE            NOT NULL,
    due_date          DATE            NULL,
    subtotal_minor    BIGINT          NOT NULL,
    tax_minor         BIGINT          NOT NULL DEFAULT 0,
    discount_minor    BIGINT          NOT NULL DEFAULT 0,
    total_minor       BIGINT          NOT NULL,
    balance_minor     BIGINT          NOT NULL DEFAULT 0,
    currency          CHAR(3)         NOT NULL,
    idempotency_key   VARCHAR(255)    NULL UNIQUE,
    created_at        TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at        TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    FOREIGN KEY (customer_id) REFERENCES customer(customer_id),
    FOREIGN KEY (subscription_id) REFERENCES subscription(subscription_id)
);

-- 13. INVOICE_LINE_ITEM
CREATE TABLE invoice_line_item (
    line_item_id      BIGINT          PRIMARY KEY AUTO_INCREMENT,
    invoice_id        BIGINT          NOT NULL,
    description       VARCHAR(255)    NOT NULL,
    line_type         ENUM('PLAN','ADDON','METERED','PRORATION','DISCOUNT','TAX') NOT NULL,
    quantity          INT             NOT NULL DEFAULT 1,
    unit_price_minor  BIGINT          NOT NULL,
    amount_minor      BIGINT          NOT NULL,
    tax_rate_id       BIGINT          NULL,
    discount_id       BIGINT          NULL,
    period_start      DATE            NULL,
    period_end        DATE            NULL,
    metadata          JSON            NULL,

    FOREIGN KEY (invoice_id) REFERENCES invoice(invoice_id),
    FOREIGN KEY (tax_rate_id) REFERENCES tax_rate(tax_id),
    FOREIGN KEY (discount_id) REFERENCES coupon(coupon_id)
);

-- 14. CREDIT_NOTE
CREATE TABLE credit_note (
    credit_note_id      BIGINT          PRIMARY KEY AUTO_INCREMENT,
    credit_note_number  VARCHAR(50)     NOT NULL UNIQUE,
    invoice_id          BIGINT          NOT NULL,
    reason              VARCHAR(255)    NOT NULL,
    amount_minor        BIGINT          NOT NULL,
    status              ENUM('DRAFT','ISSUED','APPLIED','VOIDED') NOT NULL DEFAULT 'ISSUED',
    created_by          BIGINT          NOT NULL,
    created_at          TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,

    FOREIGN KEY (invoice_id) REFERENCES invoice(invoice_id),
    FOREIGN KEY (created_by) REFERENCES user(user_id)
);

-- 15. BILLING_JOB
CREATE TABLE billing_job (
    job_id           BIGINT          PRIMARY KEY AUTO_INCREMENT,
    job_type         ENUM('CYCLE_BILLING','DUNNING_RETRY','REMINDER') NOT NULL,
    status           ENUM('PENDING','RUNNING','COMPLETED','FAILED','PARTIAL') NOT NULL,
    triggered_by     VARCHAR(100)    NOT NULL DEFAULT 'SCHEDULER',
    started_at       TIMESTAMP       NULL,
    completed_at     TIMESTAMP       NULL,
    total_records    INT             NOT NULL DEFAULT 0,
    success_count    INT             NOT NULL DEFAULT 0,
    failure_count    INT             NOT NULL DEFAULT 0,
    error_summary    TEXT            NULL,
    created_at       TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- 16. DUNNING_RETRY_LOG
CREATE TABLE dunning_retry_log (
    retry_id         BIGINT          PRIMARY KEY AUTO_INCREMENT,
    invoice_id       BIGINT          NOT NULL,
    payment_id       BIGINT          NULL,
    attempt_no       INT             NOT NULL,
    scheduled_at     TIMESTAMP       NOT NULL,
    attempted_at     TIMESTAMP       NULL,
    status           ENUM('SCHEDULED','ATTEMPTED','SUCCESS','FAILED','CANCELLED') NOT NULL,
    failure_reason   VARCHAR(255)    NULL,

    FOREIGN KEY (invoice_id) REFERENCES invoice(invoice_id),
    FOREIGN KEY (payment_id) REFERENCES payment(payment_id)
);

-- 17. PAYMENT
CREATE TABLE payment (
    payment_id         BIGINT          PRIMARY KEY AUTO_INCREMENT,
    invoice_id         BIGINT          NOT NULL,
    payment_method_id  BIGINT          NULL,
    idempotency_key    VARCHAR(100)    NOT NULL UNIQUE,
    gateway_ref        VARCHAR(200)    NULL,
    amount_minor       BIGINT          NOT NULL,
    currency           CHAR(3)         NOT NULL,
    status             ENUM('PENDING','SUCCESS','FAILED','REFUNDED','PARTIALLY_REFUNDED') NOT NULL,
    attempt_no         INT             NOT NULL DEFAULT 1,
    response_code      VARCHAR(50)     NULL,
    failure_reason     VARCHAR(255)    NULL,
    created_at         TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at         TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    FOREIGN KEY (invoice_id) REFERENCES invoice(invoice_id),
    FOREIGN KEY (payment_method_id) REFERENCES payment_method(payment_method_id)
);

-- 18. PAYMENT_METHOD
CREATE TABLE payment_method (
    payment_method_id  BIGINT          PRIMARY KEY AUTO_INCREMENT,
    customer_id        BIGINT          NOT NULL,
    payment_type       ENUM('CARD','UPI') NOT NULL,
    card_last4         CHAR(4)         NULL,
    card_brand         VARCHAR(20)     NULL,
    gateway_token      VARCHAR(255)    NOT NULL,
    is_default         BOOLEAN         NOT NULL DEFAULT FALSE,
    expiry_month       TINYINT         NULL,
    expiry_year        SMALLINT        NULL,
    status             ENUM('ACTIVE','EXPIRED','REVOKED') NOT NULL DEFAULT 'ACTIVE',
    created_at         TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,

    FOREIGN KEY (customer_id) REFERENCES customer(customer_id)
);

-- 19. TAX_RATE
CREATE TABLE tax_rate (
    tax_id           BIGINT          PRIMARY KEY AUTO_INCREMENT,
    name             VARCHAR(100)    NOT NULL,
    region           VARCHAR(50)     NOT NULL,
    rate_percent     DECIMAL(5,2)    NOT NULL,
    inclusive        BOOLEAN         NOT NULL DEFAULT FALSE,
    effective_from   DATE            NOT NULL,
    effective_to     DATE            NULL,
    created_at       TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,

    UNIQUE (region, effective_from)
);

-- 20. COUPON
CREATE TABLE coupon (
    coupon_id          BIGINT          PRIMARY KEY AUTO_INCREMENT,
    code               VARCHAR(50)     NOT NULL UNIQUE,
    name               VARCHAR(100)    NULL,
    type               ENUM('PERCENT','FIXED') NOT NULL,
    amount             BIGINT          NOT NULL,
    currency           CHAR(3)         NULL,
    duration           ENUM('ONCE','REPEATING','FOREVER') NOT NULL,
    duration_in_months INT             NULL,
    max_redemptions    INT             NULL,
    redeemed_count     INT             NOT NULL DEFAULT 0,
    valid_from         DATE            NOT NULL,
    valid_to           DATE            NULL,
    status             ENUM('ACTIVE','EXPIRED','DISABLED') NOT NULL DEFAULT 'ACTIVE',
    created_at         TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- 21. NOTIFICATION
CREATE TABLE notification (
    notification_id  BIGINT          PRIMARY KEY AUTO_INCREMENT,
    customer_id      BIGINT          NOT NULL,
    type             VARCHAR(50)     NOT NULL,
    subject          VARCHAR(255)    NULL,
    body             TEXT            NULL,
    channel          ENUM('EMAIL','SMS') NOT NULL,
    status           ENUM('PENDING','SENT','FAILED','SKIPPED') NOT NULL,
    scheduled_at     TIMESTAMP       NULL,
    sent_at          TIMESTAMP       NULL,
    created_at       TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,

    FOREIGN KEY (customer_id) REFERENCES customer(customer_id)
);

-- 22. AUDIT_LOG
CREATE TABLE audit_log (
    audit_id      BIGINT          PRIMARY KEY AUTO_INCREMENT,
    actor         VARCHAR(100)    NOT NULL,
    actor_role    VARCHAR(50)     NULL,
    action        VARCHAR(100)    NOT NULL,
    entity_type   VARCHAR(50)     NOT NULL,
    entity_id     BIGINT          NOT NULL,
    old_value     JSON            NULL,
    new_value     JSON            NULL,
    request_id    VARCHAR(100)    NULL,
    ip            VARCHAR(45)     NULL,
    created_at    TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- 23. REVENUE_SNAPSHOT
CREATE TABLE revenue_snapshot (
    snapshot_id            BIGINT          PRIMARY KEY AUTO_INCREMENT,
    snapshot_date          DATE            NOT NULL UNIQUE,
    mrr_minor              BIGINT          NOT NULL,
    arr_minor              BIGINT          NOT NULL,
    arpu_minor             BIGINT          NOT NULL,
    active_customers       INT             NOT NULL,
    new_customers          INT             NOT NULL DEFAULT 0,
    churned_customers      INT             NOT NULL DEFAULT 0,
    gross_churn_percent    DECIMAL(5,2)    NOT NULL,
    net_churn_percent      DECIMAL(5,2)    NOT NULL,
    ltv_minor              BIGINT          NOT NULL DEFAULT 0,
    total_revenue_minor    BIGINT          NOT NULL,
    total_refunds_minor    BIGINT          NOT NULL DEFAULT 0,
    created_at             TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP
);


-- =============================================
-- SEED DATA (run once at deployment)
-- =============================================

-- Product: StreamFlix (one and only product)
INSERT INTO product (name, description, status) VALUES
('StreamFlix', 'Premium streaming platform with exclusive content, multi-device support, and offline downloads.', 'ACTIVE');

-- Plans: 4 standard plans tied to StreamFlix (product_id = 1)
INSERT INTO plan (product_id, name, billing_period, default_price_minor, default_currency, trial_days, setup_fee_minor, tax_mode, effective_from, status) VALUES
(1, 'Basic Monthly',   'MONTHLY', 19900,  'INR', 7,  0, 'EXCLUSIVE', '2026-01-01', 'ACTIVE'),
(1, 'Basic Yearly',    'YEARLY',  199900, 'INR', 7,  0, 'EXCLUSIVE', '2026-01-01', 'ACTIVE'),
(1, 'Premium Monthly', 'MONTHLY', 49900,  'INR', 14, 0, 'EXCLUSIVE', '2026-01-01', 'ACTIVE'),
(1, 'Premium Yearly',  'YEARLY',  499900, 'INR', 14, 0, 'EXCLUSIVE', '2026-01-01', 'ACTIVE');

-- Price Book Entries: region-specific pricing
INSERT INTO price_book_entry (plan_id, region, currency, price_minor, effective_from) VALUES
(1, 'IN', 'INR', 19900,  '2026-01-01'),
(1, 'US', 'USD', 499,    '2026-01-01'),
(1, 'GB', 'GBP', 399,    '2026-01-01'),
(2, 'IN', 'INR', 199900, '2026-01-01'),
(2, 'US', 'USD', 4999,   '2026-01-01'),
(2, 'GB', 'GBP', 3999,   '2026-01-01'),
(3, 'IN', 'INR', 49900,  '2026-01-01'),
(3, 'US', 'USD', 999,    '2026-01-01'),
(3, 'GB', 'GBP', 799,    '2026-01-01'),
(4, 'IN', 'INR', 499900, '2026-01-01'),
(4, 'US', 'USD', 9999,   '2026-01-01'),
(4, 'GB', 'GBP', 7999,   '2026-01-01');

-- Add-on: Ad-Free Experience (tied to StreamFlix, product_id = 1)
INSERT INTO add_on (product_id, name, price_minor, currency, billing_period, tax_mode, status) VALUES
(1, 'Ad-Free Experience', 9900, 'INR', 'MONTHLY', 'EXCLUSIVE', 'ACTIVE');

-- Metered Component: Download Storage (tied to all plans)
-- 5 GB free, then ₹20/GB beyond that
INSERT INTO metered_component (plan_id, name, unit_name, price_per_unit_minor, free_tier_quantity, status) VALUES
(1, 'Download Storage', 'GB', 2000, 5, 'ACTIVE'),
(2, 'Download Storage', 'GB', 2000, 5, 'ACTIVE'),
(3, 'Download Storage', 'GB', 2000, 10, 'ACTIVE'),
(4, 'Download Storage', 'GB', 2000, 10, 'ACTIVE');

-- Tax Rates
INSERT INTO tax_rate (name, region, rate_percent, inclusive, effective_from) VALUES
('GST (India)',        'IN',    18.00, FALSE, '2026-01-01'),
('VAT (United Kingdom)', 'GB', 20.00, TRUE,  '2026-01-01'),
('Sales Tax (US-CA)',  'US-CA',  7.25, FALSE, '2026-01-01');

-- Coupons
INSERT INTO coupon (code, name, type, amount, currency, duration, duration_in_months, max_redemptions, valid_from, valid_to, status) VALUES
('WELCOME10', 'Welcome 10% Off',  'PERCENT', 10,    NULL,  'ONCE',      NULL, 500, '2026-01-01', '2026-12-31', 'ACTIVE'),
('FLAT100',   '₹100 Flat Off',    'FIXED',   10000, 'INR', 'ONCE',      NULL, 200, '2026-01-01', '2026-06-30', 'ACTIVE'),
('PREMIUM20', '20% Off Premium',  'PERCENT', 20,    NULL,  'REPEATING', 3,    100, '2026-03-01', '2026-09-30', 'ACTIVE');

SET FOREIGN_KEY_CHECKS = 1;

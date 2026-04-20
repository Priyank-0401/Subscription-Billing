## Changes Made to Supritham's Schema (and Why)

Below are the specific modifications made to Supritham's schema to produce the final merged version:

### Tables DROPPED from Supritham's schema

| Table | Why Dropped |
|-------|------------|
| `ROLE` | Supritham has 4 fixed roles (ADMIN, FINANCE, SUPPORT, CUSTOMER) in a separate table. Since these roles never change at runtime and form a strict hierarchy (ADMIN > FINANCE > SUPPORT > CUSTOMER), a single `ENUM` column on the User table is simpler. It eliminates 1 table and 1 JOIN from every auth query. Spring Security's `RoleHierarchy` handles inheritance automatically. |
| `USER_ROLE` | M:M junction for Role ↔ User. Dropped because: (1) there's no scenario in the SRS where someone needs SUPPORT + FINANCE but NOT ADMIN, (2) multiple roles cause permission conflicts (if FINANCE can't refund but SUPPORT can, what happens when a user has both?), (3) every API endpoint needs complex `hasAnyRole()` checks instead of simple hierarchy. |

### Tables ADDED that Supritham doesn't have

| Table | Why Added |
|-------|----------|
| `REVENUE_SNAPSHOT` | US 07 requires MRR/ARR/Churn analytics with historical trends. Without daily snapshots stored in a table, you'd need to recompute metrics from raw Invoice/Subscription data every time the dashboard loads — expensive and slow. Supritham's schema covers formulas but doesn't store results. |

### Columns CHANGED on Supritham's tables

#### USER table
| Change | Why |
|--------|-----|
| Added `role ENUM('CUSTOMER','SUPPORT','FINANCE','ADMIN') DEFAULT 'CUSTOMER'` | Replaces the dropped Role + User_Role tables. Default is CUSTOMER because public signups auto-assign this role. Staff roles are set by admins via admin panel. |
| `password_hash` kept as NULL-able (same as Supritham) | Supritham correctly notes NULL = OAuth2 user. Local/dev accounts set this. |
| Added `SUSPENDED` to status ENUM | Supritham already has this — keeping it. |

#### CUSTOMER table
| Change | Why |
|--------|-----|
| Added `user_id BIGINT NOT NULL UNIQUE, FK → User` | **Supritham's schema has NO link between User and Customer.** This is a critical gap. Without this FK, there's no way to know which login (User) owns which billing profile (Customer). When a logged-in user views "My Subscriptions", the system can't connect their JWT token (which identifies a User) to their Customer record. |
| Removed `name` and `email` columns | These already exist on the User table. Duplicating them causes data inconsistency — if a user changes their email via account settings, you'd need to update it in TWO tables. With `user_id` FK, you JOIN to User for name/email. Single source of truth. |
| Kept Supritham's structured address (country, state, city, etc.) | Supritham is right — a single `address VARCHAR(255)` cannot be parsed for tax computation. GST needs `country = 'IN'` + `state = 'Maharashtra'` to determine intra-state vs inter-state tax. Structured fields avoid regex nightmares. |

#### PLAN table
| Change | Why |
|--------|-----|
| `trial_days DEFAULT 7` instead of Supritham's `DEFAULT 0` | Project decision — all plans in this streaming platform get a 7-day free trial. |
| Removed `proration_behavior` column | Project decision — all plans use prorated billing for mid-cycle upgrades. Since every row would have the same value, it's a business rule (hardcoded in billing service), not a column. |
| Changed `billing_period` to `ENUM('MONTHLY','YEARLY')` | Supritham has `QUARTERLY` — dropped because this streaming platform only offers monthly and yearly billing. Keeping it simple. |
| Kept `ACTIVE/INACTIVE` instead of Supritham's `ACTIVE/ARCHIVED` | The SRS doesn't specify ARCHIVED for plans. INACTIVE allows re-activation; ARCHIVED implies permanent retirement. For this project, INACTIVE is sufficient. |

#### METERED_COMPONENT table
| Change | Why |
|--------|-----|
| Kept Supritham's `plan_id` FK (not product_id) | Supritham is right — metered components belong to a plan, not a product. Different plans under the same product offer different free quotas (Basic = 5GB free, Pro = 15GB). Plan-level FK handles this naturally. |
| Kept `ACTIVE/INACTIVE` instead of `ACTIVE/ARCHIVED` | Consistency with Plan table status values. |

#### ADD_ON table  
| Change | Why |
|--------|-----|
| Added `billing_period ENUM('MONTHLY','YEARLY')` | Supritham doesn't have this. Add-ons can have their own billing period — a monthly add-on on a yearly plan is valid (e.g., "4K Quality ₹99/mo" on an Annual plan). |

#### SUBSCRIPTION table
| Change | Why |
|--------|-----|
| Kept Supritham's `ON_HOLD` status | Good addition — SRS 6.6 says after max retries: "cancel or hold (configurable)." ON_HOLD is the "hold" state. Without it, you can only cancel. |
| Kept Supritham's `trial_end_date` | Correct — storing explicitly is safer than deriving from `start_date + trial_days`. If the plan is changed mid-trial, the derived value would break. |
| Kept Supritham's `canceled_at` | Needed for churn analytics — "when did this customer cancel?" can't be answered from status alone if it gets overwritten. |

#### SUBSCRIPTION_ITEM table
| Change | Why |
|--------|-----|
| Used Supritham's separate FK columns (`plan_id`, `addon_id`, `component_id`) instead of Priyank's single `reference_id` | With separate columns, the database can enforce FK constraints on each. A generic `reference_id` pointing to 3 different tables cannot have a foreign key — the DB can't check integrity. Separate columns = database-level protection against orphaned references. |

#### INVOICE table
| Change | Why |
|--------|-----|
| Added `idempotency_key VARCHAR(255) UNIQUE` | **Supritham's schema is missing this.** SRS US-02 explicitly requires idempotency to prevent duplicate charges. Without this key, if the billing cron runs twice (network retry, server restart), the same subscription gets invoiced twice. The idempotency_key ensures the second attempt returns the existing invoice instead of creating a new one. |
| Kept Supritham's `billing_reason` ENUM | Good addition — "WHY was this invoice created?" is critical for analytics (new subscription vs renewal vs plan change vs manual). |
| Used Supritham's status values: `DRAFT, OPEN, PAID, VOID, UNCOLLECTIBLE` | Better than Priyank's `FINALIZED, PAYMENT_FAILED`. `OPEN` is clearer (invoice is sent, awaiting payment). `UNCOLLECTIBLE` is clearer than `PAYMENT_FAILED` (all retries exhausted, written off). |

#### PAYMENT table
| Change | Why |
|--------|-----|
| Added `payment_method_id BIGINT FK → PaymentMethod` | **Supritham's schema is missing this.** Without it, you don't know WHICH card was charged for a payment. If a customer has 3 cards and disputes a charge, support can't tell which card was used. |
| Kept Supritham's `PARTIALLY_REFUNDED` status | Good addition — partial refunds are in scope (SRS US-08). Without this status, a partial refund would show as fully `REFUNDED`, which is misleading. |
| Kept Supritham's `failure_reason` | Needed for dunning (tell customer WHY it failed) and support workflows. |

#### COUPON table
| Change | Why |
|--------|-----|
| Used simple whole number for PERCENT (20 = 20%) instead of Supritham's basis points (2000 = 20%) | Basis points are an enterprise/fintech convention. For a college project streaming platform, `20` meaning "20%" is intuitive for the whole team. Basis points add confusion without benefit at this scale. |
| Kept Supritham's `currency` column | Correct — a FIXED coupon of `10000` means ₹100 in INR but $100 in USD. Without `currency`, you can't distinguish. |
| Kept Supritham's `name` column | Good for display — "Diwali Sale 20%" is more readable than just code `DIWALI20`. |
| Used `DISABLED` instead of Supritham's `ARCHIVED` for status | DISABLED is clearer — admin manually turned it off. ARCHIVED implies time-based expiry. |

#### CREDIT_NOTE table
| Change | Why |
|--------|-----|
| Kept Supritham's full lifecycle status: `DRAFT, ISSUED, APPLIED, VOIDED` | Better than Priyank's single type ENUM. A VOIDED credit note cannot be applied again — prevents double-application. The status tracks the credit note through its lifecycle. |

#### NOTIFICATION table
| Change | Why |
|--------|-----|
| Kept Supritham's `scheduled_at` | Needed for T-7/T-1 renewal reminders. Without it, you can't queue a notification to be sent 7 days before billing — you'd need a separate scheduling mechanism. |
| Kept Supritham's `PENDING` and `SKIPPED` statuses | PENDING = notification created but not yet sent (scheduled for future). SKIPPED = customer opted out of this notification type. |

#### AUDIT_LOG table
| Change | Why |
|--------|-----|
| Kept Supritham's `actor_role VARCHAR(50)` | Snapshot of role at action time. If an admin is later demoted to support, the audit log should still show they were ADMIN when they issued that refund. |
| Kept Supritham's `JSON` type for old_value/new_value | Structured and queryable, unlike TEXT. You can query `JSON_EXTRACT(new_value, '$.status')` for specific field changes. |
| Kept Supritham's `VARCHAR(45)` for ip | IPv6 addresses can be up to 39 chars; 45 covers IPv4-mapped-IPv6 format. Priyank's `VARCHAR(50)` works too but 45 is more precise. |

---

## All 21 Tables — Overview

| # | Table | Description |
|---|-------|-------------|
| 1 | `user` | Internal portal users and customer login accounts with role-based access |
| 2 | `customer` | Billing profile created when a user first subscribes — holds address, currency, tax region |
| 3 | `product` | Top-level catalog item (e.g., "StreamFlix") that plans and add-ons belong to |
| 4 | `plan` | Pricing tier under a product with billing period, trial days, setup fee, and tax mode |
| 5 | `price_book_entry` | Regional price overrides per plan — one plan, different prices per country/currency |
| 6 | `add_on` | Optional paid extras that can be added to any subscription (e.g., "4K Quality", "No Ads") |
| 7 | `metered_component` | Usage-based billing definitions — what is measured, price per unit, free tier quota |
| 8 | `subscription` | Active customer-plan relationship tracking the full lifecycle from trial to cancellation |
| 9 | `subscription_item` | Individual components within a subscription: the base plan, add-ons, and metered items |
| 10 | `subscription_coupon` | Junction table linking subscription-level coupons (e.g., "20% off for 3 months") |
| 11 | `usage_record` | Actual metered consumption logged per subscription per billing period |
| 12 | `invoice` | Generated bill for a billing period with line-item totals, taxes, and discounts |
| 13 | `invoice_line_item` | Individual charges on an invoice — plan, add-on, metered, proration, discount, tax |
| 14 | `credit_note` | Refund documentation linked to an invoice with lifecycle tracking |
| 15 | `billing_job` | Tracks each cron job run — cycle billing, dunning retries, reminders |
| 16 | `dunning_retry_log` | Per-attempt retry logging for failed payments with scheduled/actual timestamps |
| 17 | `payment` | Individual payment attempt against an invoice with gateway response and idempotency |
| 18 | `payment_method` | Tokenized payment instruments — cards, UPI — with no raw PAN storage |
| 19 | `tax_rate` | Region-based tax rules (GST/VAT) with inclusive/exclusive modes and effective dates |
| 20 | `coupon` | Discount codes with percentage/fixed types, duration control, and usage limits |
| 21 | `notification` | Notification delivery log — reminders, receipts, failure alerts via email/SMS |
| 22 | `audit_log` | Immutable, append-only record of all monetary actions for compliance |
| 23 | `revenue_snapshot` | Daily snapshot of KPIs — MRR, ARR, ARPU, churn — for historical analytics |

---

## Complete SQL DDL

### 1. USER
```sql
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

-- Seed first admin at deployment
INSERT INTO user (full_name, email, password_hash, role, status)
VALUES ('System Admin', 'admin@streamflix.com', '$2a$10$...bcrypt_hash...', 'ADMIN', 'ACTIVE');
```

---

### 2. CUSTOMER
```sql
-- Created when user first subscribes (NOT at signup)
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
```

---

### 3. PRODUCT
```sql
CREATE TABLE product (
    product_id       BIGINT          PRIMARY KEY AUTO_INCREMENT,
    name             VARCHAR(100)    NOT NULL,
    description      TEXT            NULL,
    status           ENUM('ACTIVE','INACTIVE') NOT NULL DEFAULT 'ACTIVE',
    created_at       TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at       TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);
```

---

### 4. PLAN
```sql
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
```

---

### 5. PRICE_BOOK_ENTRY
```sql
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
```

---

### 6. ADD_ON
```sql
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
```

---

### 7. METERED_COMPONENT
```sql
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
```

---

### 8. SUBSCRIPTION
```sql
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
```

---

### 9. SUBSCRIPTION_ITEM
```sql
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
```

---

### 10. SUBSCRIPTION_COUPON
```sql
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
```

---

### 11. USAGE_RECORD
```sql
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
```

---

### 12. INVOICE
```sql
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
```

---

### 13. INVOICE_LINE_ITEM
```sql
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
```

---

### 14. CREDIT_NOTE
```sql
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
```

---

### 15. BILLING_JOB
```sql
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
```

---

### 16. DUNNING_RETRY_LOG
```sql
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
```

---

### 17. PAYMENT
```sql
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
```

---

### 18. PAYMENT_METHOD
```sql
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
```

---

### 19. TAX_RATE
```sql
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
```

---

### 20. COUPON
```sql
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
```

---

### 21. NOTIFICATION
```sql
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
```

---

### 22. AUDIT_LOG
```sql
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
```

---

### 23. REVENUE_SNAPSHOT
```sql
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
```

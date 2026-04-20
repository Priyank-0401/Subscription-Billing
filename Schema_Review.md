# Schema Review — Subscription Billing & Revenue Management System

> Complete review of the current 14-table schema, with proposed changes, new tables for metered billing, and full data flow mapping.

---

## 🔴 Question 1: User vs Customer — Who is a "Customer"?

### Your instinct is correct. A User ≠ Customer at signup.

Here's the industry-standard breakdown:

| Concept | When Created | Purpose |
|---------|-------------|---------|
| **User** | At **signup** | Authentication identity. They can log in, browse, exist in the system. |
| **Customer** | At **first purchase** (subscription) | Billing identity. They have a currency, payment method, invoices, subscriptions. |

#### Real-World Analogy
- **Netflix**: You create an account (User). You're not a "customer" until you pick a plan and enter your card. If you're on a free trial and never convert, Netflix doesn't track you as a revenue-generating customer.
- **Stripe**: Explicitly has `User` (login) and `Customer` (billing entity) as separate objects. A Customer is created only when a billing relationship begins.

#### What your teammates are thinking (and why it's partially valid)
In many **simple streaming apps**, they auto-create a Customer record at signup because:
- Every user *will* subscribe (no free tier exists)
- It simplifies the code — one entity instead of two

But this conflates two different responsibilities and causes complications (see below).

### ⚠️ Complications of treating User = Customer at signup

| # | Problem | Impact |
|---|---------|--------|
| 1 | **Phantom customers in analytics** | Your MRR, ARPU, churn dashboards will count users who never paid. A user who signed up and bounced inflates your `active_customers` count and deflates ARPU. |
| 2 | **Currency assignment problem** | Customer table requires `currency`. At signup you don't know what currency the user will pay in. You'd have to guess or default, and changing it later after invoices exist is a nightmare. |
| 3 | **Payment method chicken-and-egg** | If Customer exists at signup, does PaymentMethod also need to exist? Now you have customers with no payment methods, subscriptions can't validate, and null-checks proliferate everywhere. |
| 4 | **Coupon/discount scope confusion** | Coupons are applied to Customers. If everyone is a Customer, a "new customer discount" applies to someone who signed up 6 months ago and never paid. |
| 5 | **Audit & compliance noise** | Audit logs will be full of "Customer created" events for people who never transacted. Real monetary audit gets buried in noise. |
| 6 | **Churn calculation breaks** | Churn = customers who cancel / total customers. If User=Customer, someone who signed up and never subscribed counts as a "non-churned" customer, making churn rates misleadingly low. |
| 7 | **Multi-currency issues** | A User might sign up from India but later subscribe with USD pricing (corporate account). If you locked them into INR at signup, you have a conflict. |

### ✅ Recommended Approach

```
User (authentication)                Customer (billing)
┌──────────────────┐                ┌──────────────────┐
│ user_id          │   1:0..1       │ customer_id      │
│ email            │───────────────▶│ user_id (FK)     │
│ password_hash    │  Created when  │ currency         │
│ status           │  user first    │ phone            │
│ created_at       │  subscribes    │ address          │
└──────────────────┘                └──────────────────┘
```

- **User** is created at signup → can browse, log in
- **Customer** is created when they first subscribe → has billing info, currency, payment methods
- Link: `customer.user_id → user.user_id` (one-to-one, nullable from User side)
- The Customer Portal shows "Complete your profile" (currency, phone, address) as part of the subscription onboarding flow

---

## 🔴 Question 2: Metered Components — Are they necessary?

**Yes, if your SRS scope includes them, you must implement them.** Your SRS (Section: Catalog) explicitly mentions "metered components" and US 03 says:

> *"CRUD for product, plan, add-on, **metered component**"*

For a streaming platform, metered charges are things like:
- **Extra storage** (beyond plan limit) — charged per GB
- **Premium downloads** (beyond monthly limit) — charged per download
- **Simultaneous streams** (beyond plan limit) — charged per extra stream
- **API calls** (if B2B streaming) — charged per 1000 calls

### Your current Metered Item table is too rigid

Your current `Metered_Item` has `fixed_storage ENUM(5,7,15)` — this hardcodes storage tiers and doesn't generalize. 

Metered components should be **catalog-level definitions** (what CAN be metered), and **usage records** should track actual consumption per subscription per period.

---

## 📋 Table-by-Table Review of Current Schema

### Current Tables (14 from images)

I've extracted all 14 tables from your Excel screenshots. Here's every issue:

---

### 1. `User` Table
**Current:**
```
user_id       BIGINT        PK, AUTO_INCREMENT
full_name     VARCHAR(100)  NOT NULL
email         VARCHAR(120)  UNIQUE, NOT NULL
password      VARCHAR(18)   NOT NULL
status        VARCHAR(20)   DEFAULT 'ACTIVE', CHECK (ACTIVE/INACTIVE)
created_at    TIMESTAMP     DEFAULT CURRENT_TIMESTAMP
updated_at    TIMESTAMP     ON UPDATE CURRENT_TIMESTAMP
```

**Issues:**

| Issue | Problem | Fix |
|-------|---------|-----|
| `password VARCHAR(18)` | **CRITICAL** — BCrypt hashes are 60 chars, Argon2 hashes are ~97 chars. 18 chars can only store a raw password (security violation). | Change to `VARCHAR(255)` and rename to `password_hash` |
| `full_name` | Single field can't sort by last name or address formally | Acceptable for this project, but note the limitation |
| No `role` column | You have a separate Role + User_Role table, which is overkill for 4 fixed roles | See recommendation below |

**Recommended Changes:**
```sql
password_hash   VARCHAR(255)   NOT NULL   -- renamed + resized
-- Consider dropping Role and User_Role tables, use ENUM instead:
role            ENUM('ADMIN','FINANCE','SUPPORT','CUSTOMER')  NOT NULL
```

---

### 2. `Role` + `User_Role` Tables
**Current:**
```
Role:      role_id (PK), role_name VARCHAR(100) UNIQUE
User_Role: user_id (FK→User), role_id (FK→Role), composite PK
```

**Issues:**

| Issue | Problem | Fix |
|-------|---------|-----|
| Over-engineering | You have exactly 4 fixed roles (ADMIN, FINANCE, SUPPORT, CUSTOMER) that will never change at runtime. A many-to-many relation is overkill. | Use an ENUM column on User table |
| Composite PK | Having (user_id, role_id) as composite PK means a user can have multiple roles. Does your SRS require multi-role users? For this project, unlikely. | Single role per user via ENUM |

> [!TIP]
> **Recommendation**: Drop `Role` and `User_Role` tables entirely. Add `role ENUM('ADMIN','FINANCE','SUPPORT','CUSTOMER')` to the `User` table. This removes 2 tables and 1 join from every auth query. Your SRS defines exactly 4 roles — no need for a dynamic role table.

If your team insists on keeping them (for "extensibility"), that's fine — it works, it's just unnecessary complexity for this scope.

---

### 3. `Customer` Table
**Current:**
```
customer_id      BIGINT        PK, AUTO_INCREMENT
customer_name    VARCHAR(100)  NOT NULL
email            VARCHAR(100)  NOT NULL, UNIQUE
phone            VARCHAR(10)   CHECK(LEN=10)
currency         VARCHAR(10)   NOT NULL
address          VARCHAR(255)  NULL
customer_status  ENUM(ACTIVE,INACTIVE)  CHECK
created_at       TIMESTAMP
updated_at       TIMESTAMP
country_code     VARCHAR(7)/ENUM('+91','+1','+44')
```

**Issues:**

| Issue | Problem | Fix |
|-------|---------|-----|
| No `user_id` FK | Customer is completely disconnected from User. How do you know which login owns which billing profile? | Add `user_id BIGINT FK → User(user_id), UNIQUE` |
| `email` duplicated | Email already exists on User table. Customer shouldn't duplicate it unless you want billing-specific email. | Remove or rename to `billing_email` (optional) |
| `phone VARCHAR(10)` | Only works for India (10 digits). International numbers are 7-15 digits. | Change to `VARCHAR(20)` |
| `country_code ENUM('+91','+1','+44')` | Hardcoded to only 3 countries. What if you add Australia? | Change to `VARCHAR(5)` or drop and derive from `region` |
| `customer_status` only ACTIVE/INACTIVE | SRS defines ACTIVE, INACTIVE, SUSPENDED | Add `SUSPENDED` to the enum |
| `currency VARCHAR(10)` | ISO-4217 codes are exactly 3 chars (INR, USD, EUR) | Change to `VARCHAR(3)` or `CHAR(3)` |
| Missing `region` | Tax calculation needs customer region. Without it, you can't determine GST vs VAT. | Add `region VARCHAR(50)` |

---

### 4. `Product` Table
**Current:**
```
product_id           BIGINT        PK, AUTO_INCREMENT
product_name         VARCHAR(100)  NOT NULL
product_description  VARCHAR(200)  NOT NULL
product_status       ENUM(ACTIVE/INACTIVE)  DEFAULT ACTIVE
created_at           TIMESTAMP
updated_at           TIMESTAMP
```

**Issues:**

| Issue | Problem | Fix |
|-------|---------|-----|
| `product_description VARCHAR(200)` | Too short for rich descriptions. | Change to `TEXT` or at least `VARCHAR(500)` |
| `product_description NOT NULL` | Should be optional — a product might not need a description initially | Change to `NULL` allowed |
| Missing `ARCHIVED` status | SRS defines `ACTIVE, ARCHIVED` for products, not `INACTIVE` | Change enum to `ENUM('ACTIVE','ARCHIVED')` |

Otherwise this table is clean. ✅

---

### 5. `Plan` Table
**Current:**
```
plan_id          BIGINT
product_id       BIGINT (FK)
name             VARCHAR(20)
billing_period   ENUM(Monthly/Yearly)
price_minor      NUMERIC(6,2)
currency         ENUM(INR/EUR/USD)
trial_days       Default 7
setup_fee_minor  BIGINT
tax_mode         ENUM(Default Exclusive)
effective_from   TIMESTAMP
effective_to     TIMESTAMP
status           ENUM(ACTIVE/INACTIVE)
```

**Issues:**

| Issue | Problem | Fix |
|-------|---------|-----|
| `name VARCHAR(20)` | Too short. "Premium Annual Family Plan" = 27 chars | Change to `VARCHAR(100)` |
| `price_minor NUMERIC(6,2)` | **CRITICAL** — Minor units are integers (paise/cents). Using NUMERIC with decimals defeats the purpose. Also 6,2 maxes at 9999.99 which is only ~₹99. | Change to `BIGINT` (stores 49900 for ₹499.00) |
| `currency ENUM(INR/EUR/USD)` | Not extensible. If you add GBP later, you change the schema. | Change to `VARCHAR(3)` |
| Missing `proration_mode` | SRS defines `ENUM(PRORATED, FULL_CYCLE)` on Plan | Add this column |
| `trial_days Default 7` | Should default to `0` (most plans don't have trials) | Change default to `0` |

---

### 6. `Subscription` Table
**Current:**
```
subscription_id       BIGINT        PK, AUTO_INCREMENT
customer_id           BIGINT        FK → Customer
plan_id               BIGINT        FK → Plan
status                ENUM(DRAFT/TRIALING/ACTIVE/PAST_DUE/PAUSED/CANCELLED)
start_date            TIMESTAMP     reference payment method
current_period_start  DEFAULT(TRIAL+7)
current_period_end    TIMESTAMP     DEPEND ON PLAN ID AND BILLING PERIOD
cancel_at_period_end  BOOLEAN       DEFAULT FALSE
paused_from           TIMESTAMP     DEFAULT NULL
paused_to             TIMESTAMP     DEFAULT NULL
payment_method_id     BIGINT        FK → Payment_Method
currency              ENUM(INR/EUR/USD)
```

**Issues:**

| Issue | Problem | Fix |
|-------|---------|-----|
| `current_period_start DEFAULT(TRIAL+7)` | This is application logic, not a DB default. The start depends on trial_days from the Plan and subscription start_date. | Remove default, set via application code |
| `currency ENUM` | Same as Plan — not extensible | Change to `VARCHAR(3)` |
| Missing `created_at`, `updated_at` | Every table needs audit timestamps | Add both |
| Status is good ✅ | Matches SRS lifecycle perfectly | Keep as-is |

---

### 7. `Subscription Item` Table
**Current:**
```
subscription_item_id  BIGINT        PK, AUTO_INCREMENT
subscription_id       BIGINT        FK → Subscription
item_type             VARCHAR(30)
unit_price_minor      NUMERIC(5,2)
quantity              BIGINT        DEFAULT 0
tax_mode              ENUM(Default Exclusive)
discount_id           BIGINT        FK → Coupon
metered_item_id       BIGINT        FK → Metered_Item
```

**Issues:**

| Issue | Problem | Fix |
|-------|---------|-----|
| `item_type VARCHAR(30)` | Should be an ENUM for data integrity | Change to `ENUM('BASE_PLAN','ADD_ON','METERED')` |
| `unit_price_minor NUMERIC(5,2)` | Same problem as Plan — minor units must be integer | Change to `BIGINT` |
| `quantity BIGINT DEFAULT 0` | Quantity can't be 0 — that means 0 items. Default should be 1. Also BIGINT is overkill for quantity, INT is fine. | `INT DEFAULT 1` |
| `metered_item_id` FK | Good that you have this! But rename for clarity | Consider `metered_component_id` |
| Missing `reference_id` | SRS specifies a `reference_id` that points to the Plan or AddOn id depending on `item_type` | Add `reference_id BIGINT NOT NULL` |

---

### 8. `Invoice` Table
**Current:**
```
invoice_id        BIGINT
customer_id       BIGINT        FK → Customer
subscription_id   BIGINT        FK → Subscription
status            ENUM
issue_date        CURRENT_TIMESTAMP
due_date          TIMESTAMP     TO BE DECIDED
sub_total_minor   BIGINT        DEFAULT NULL, TO BE DECIDED
tax_minor         NUMERIC(7,2)
discount_minor    NUMERIC(7,2)  FK → Coupon
total_minor       NUMERIC(8,2)  AMOUNT AFTER DISCOUNT + TAX
balance_minor     NUMERIC(8,2)  DEFAULT 0
currency          ENUM(INR/EUR/USD)
```

**Issues:**

| Issue | Problem | Fix |
|-------|---------|-----|
| `tax_minor NUMERIC(7,2)` | Again — minor units must be BIGINT, not decimal | Change all `*_minor` to `BIGINT` |
| `discount_minor FK → Coupon` | discount_minor is a money amount, not an FK. The FK should be on the line item level, not invoice level. | Remove FK, keep as `BIGINT` (amount) |
| Missing `invoice_number` | SRS requires a human-readable invoice number like `INV-2026-0001` | Add `invoice_number VARCHAR(50) UNIQUE NOT NULL` |
| Missing `idempotency_key` | SRS requires this to prevent duplicate billing | Add `idempotency_key VARCHAR(255) UNIQUE` |
| Missing `created_at`, `updated_at` | Audit timestamps | Add both |
| Status values unclear | SRS defines: `DRAFT, FINALIZED, PAID, VOID, PAYMENT_FAILED` | Ensure ENUM matches |

---

### 9. `Invoice Line Item` Table
**Current:**
```
invoice_line_item_id  BIGINT        PK, AUTO_INCREMENT
invoice_id            BIGINT        FK → Invoice
description           (comment: IS IT OF PLAN, ADDON, METERED USAGE)
quantity              BIGINT
unit_price_minor      BIGINT
amount_minor          BIGINT        AFTER UNIT PRICE - DISCOUNT + TAX
tax_rate_id           BIGINT        FK → TaxRate
discount_id           BIGINT        FK → Coupon
metadata              JSON
```

**Issues:**

| Issue | Problem | Fix |
|-------|---------|-----|
| `description` has no type defined | Missing datatype | `VARCHAR(500) NOT NULL` |
| Missing `line_type` | SRS defines `ENUM(CHARGE, CREDIT, PRORATION)` — needed to distinguish prorated credits from regular charges | Add `line_type ENUM('CHARGE','CREDIT','PRORATION') DEFAULT 'CHARGE'` |
| `quantity BIGINT` | Overkill. INT is sufficient. | Change to `INT DEFAULT 1` |
| Missing `created_at` | Audit timestamp | Add |

Otherwise the structure is quite good. ✅

---

### 10. `Metered Item` Table  ← **NEEDS MAJOR REDESIGN**
**Current:**
```
metered_item_id   BIGINT        PK, AUTO_INCREMENT
fixed_storage     ENUM(5,7,15)
unit_price_minor  NUMERIC(5,2)
tax_mode          ENUM(inclusive/exclusive)
```

**Issues:**

| Issue | Problem | Fix |
|-------|---------|-----|
| **Entire design is wrong** | This is hardcoded to storage tiers. What about download limits? Stream limits? API calls? | Redesign as a generic `Metered_Component` |
| `fixed_storage ENUM(5,7,15)` | Not a metered component — this is a plan feature limit. Metered means "pay per unit consumed". | Remove. Plan limits go into Plan table or a PlanFeature table. |
| No `product_id` FK | A metered component must belong to a product, just like Plans and AddOns do | Add FK |
| No `name` | No way to identify what this component is (Storage? Downloads? Streams?) | Add `name VARCHAR(100)` |
| `unit_price_minor NUMERIC(5,2)` | Integer issue again | `BIGINT` |

---

### 11. `Usage Record` Table
**Current:**
```
usage_id          BIGINT        PK, AUTO_INCREMENT
subscription_id   BIGINT        FK → Subscription
metered_item_id   BIGINT        FK → Metered_Item
used_units        BIGINT
```

**Issues:**

| Issue | Problem | Fix |
|-------|---------|-----|
| Missing `recorded_at` | When did this usage happen? Critical for billing periods. | Add `TIMESTAMP NOT NULL` |
| Missing `billing_period_start/end` | Which billing period does this usage belong to? Without this, you can't aggregate usage per cycle. | Add period reference |
| `used_units BIGINT` | Should this be cumulative or incremental? Need clarity. | Rename to `quantity` and document as incremental |
| Missing `idempotency_key` | Duplicate usage reports can double-charge | Add for safety |

---

### 12. `Payment` Table
**Current:**
```
payment_id     BIGINT        PK, AUTO_INCREMENT
invoice_id     BIGINT        FK → Invoice
gateway_ref    VARCHAR(200)  references invoice
amount_minor   (missing type info)
currency       ENUM(INR/EUR/USD)
status         ENUM(SUCCESS/FAIL)
attempt_no     BIGINT        DEFAULT 0
response_code  INT
created_at     TIMESTAMP     CURRENT_TIMESTAMP
```

**Issues:**

| Issue | Problem | Fix |
|-------|---------|-----|
| `status ENUM(SUCCESS/FAIL)` | SRS defines `PENDING, SUCCEEDED, FAILED, REFUNDED` — you're missing 2 states | Fix enum |
| Missing `payment_method_id` FK | You don't know WHICH card was charged | Add FK → PaymentMethod |
| Missing `idempotency_key` | **CRITICAL** — SRS requires this for duplicate charge prevention | Add `VARCHAR(255) UNIQUE NOT NULL` |
| `attempt_no BIGINT DEFAULT 0` | Should be `INT`, and first attempt is 1, not 0 | `INT DEFAULT 1` |
| `currency ENUM` | Same extensibility issue | `VARCHAR(3)` |
| `amount_minor` missing type | Likely BIGINT but undefined in sheet | `BIGINT NOT NULL` |

---

### 13. `Tax Rate` Table
**Current:**
```
tax_id          BIGINT        PK, AUTO_INCREMENT
(column)        ENUM()        NOT NULL    ← appears to be region
(column)        ENUM()        NOT NULL    ← appears to be name
rate_percent    BOOLEAN(?)    DEFAULT FALSE  ← seems mixed up
inclusive       CURRENT_TIMESTAMP  ← seems mis-aligned
effective_from  TIMESTAMP
effective_to    TIMESTAMP     NULL
```

**Issues:**

The columns appear misaligned in the screenshot. Here's what it should be:

| Issue | Problem | Fix |
|-------|---------|-----|
| Column names unclear | Screenshots show misaligned data | Redefine cleanly |
| Missing `name` | Tax rate needs a label like "GST 18%" or "VAT 20%" | Add `name VARCHAR(100) NOT NULL` |
| `rate_percent` | Should be `DECIMAL(5,2)` to handle 18.50% etc. | Fix type |
| `region` | Use `VARCHAR(50)` not ENUM — regions can be dynamic | Fix type |

---

### 14. `Coupon` Table
**Current:**
```
coupon_id          BIGINT         PK, AUTO_INCREMENT
code               VARCHAR(10)    UNIQUE, NOT NULL
code_type          ENUM(FIXED/PERCENT)  NOT NULL
amount             CASE WHEN FIXED,PERCENT
duration           ENUM(ONCE/RECURRING)
duration_in_months NVL(TO_CHAR('mm'))
max_redemptions    BIGINT
redeem_count       BIGINT
valid_from         TIMESTAMP
valid_to           TIMESTAMP
status             ENUM(ACTIVE/EXPIRED)
```

**Issues:**

| Issue | Problem | Fix |
|-------|---------|-----|
| `code VARCHAR(10)` | Too short. Promo codes like `SUMMER2026LAUNCH` are >10 chars | `VARCHAR(50)` |
| `duration` missing `FOREVER` | SRS defines `ONCE, REPEATING, FOREVER` — you're missing FOREVER | Add to enum |
| `duration_in_months NVL(TO_CHAR('mm'))` | This is Oracle syntax, not MySQL. And it's application logic, not a default. | Just use `INT NULL` |
| `amount` type unclear | If FIXED, this is in minor units (BIGINT). If PERCENT, it's 1-100. | `BIGINT NOT NULL` (for FIXED: minor units; for PERCENT: whole number like 20 for 20%) |
| `status` missing `DISABLED` | SRS defines `ACTIVE, EXPIRED, DISABLED` | Add to enum |
| `max_redemptions`, `redeem_count` as BIGINT | INT is sufficient — you won't have billions of redemptions | Change to `INT` |

---

### 15. `Payment Method` Table
**Current:**
```
customer_id          BIGINT        FK → Customer
card_ending_4_digit  INT           NOT NULL
payment_type         ENUM(CARD/UPI)
is_default           BOOLEAN
expiry_date          DATE
payment_method_id    BIGINT        PK, AUTO_INCREMENT
```

**Issues:**

| Issue | Problem | Fix |
|-------|---------|-----|
| PK at bottom | Minor — move `payment_method_id` to top for readability | Reorder |
| `card_ending_4_digit INT` | An INT drops leading zeros. Card "0042" becomes 42. | Change to `VARCHAR(4)` |
| Missing `token` | SRS requires tokenized payment storage. You need a token field for the mock gateway. | Add `token VARCHAR(255) NOT NULL` |
| Missing `card_brand` | Visa, Mastercard, RuPay — needed for display and mock processing | Add `VARCHAR(20)` |
| `expiry_date DATE` | Cards expire by month/year, not specific date. Store as month + year separately for proper validation. | Change to `expiry_month INT, expiry_year INT` |
| Missing `created_at` | Audit timestamp | Add |

---

### 16. `Notification` Table — Looks Good ✅
Minor issue: Missing `body TEXT` for notification content, and missing `reference_id` to link back to the triggering entity (invoice, subscription).

### 17. `Credit Note` Table — Looks Good ✅
Minor issue: Missing `credit_note_no VARCHAR(50) UNIQUE` for human-readable numbering, and missing `type ENUM(REFUND, ADJUSTMENT, PRORATION_CREDIT)`.

### 18. `Audit Log` Table — Looks Good ✅
Minor: Most column types are undefined in the screenshot. Ensure proper types are assigned.

---

## 🆕 Tables You're Missing (Must Add)

### 1. `AddOn` Table (Missing entirely!)

Your SRS mentions AddOns everywhere but you have no table for them.

```sql
CREATE TABLE add_on (
    add_on_id        BIGINT          PRIMARY KEY AUTO_INCREMENT,
    product_id       BIGINT          NOT NULL,     -- FK → Product
    name             VARCHAR(100)    NOT NULL,
    price_minor      BIGINT          NOT NULL,     -- in paise/cents
    currency         VARCHAR(3)      NOT NULL,
    billing_period   ENUM('MONTHLY','YEARLY') NOT NULL,
    status           ENUM('ACTIVE','INACTIVE') NOT NULL DEFAULT 'ACTIVE',
    created_at       TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    
    FOREIGN KEY (product_id) REFERENCES product(product_id)
);
```
**Why needed**: US 01 says "subscribe to a plan with optional add-ons". Without this table, you can't define what add-ons exist.

---

### 2. `Metered_Component` Table (Replaces your broken `Metered_Item`)

```sql
CREATE TABLE metered_component (
    component_id      BIGINT          PRIMARY KEY AUTO_INCREMENT,
    product_id        BIGINT          NOT NULL,     -- FK → Product
    name              VARCHAR(100)    NOT NULL,      -- "Extra Storage", "Premium Downloads"
    code              VARCHAR(50)     NOT NULL UNIQUE, -- "extra_storage", "downloads"
    unit_name         VARCHAR(30)     NOT NULL,      -- "GB", "download", "stream"
    price_per_unit    BIGINT          NOT NULL,      -- price per unit in minor units
    currency          VARCHAR(3)      NOT NULL,
    tax_mode          ENUM('INCLUSIVE','EXCLUSIVE') NOT NULL DEFAULT 'EXCLUSIVE',
    included_units    INT             NOT NULL DEFAULT 0,  -- free units in plan
    status            ENUM('ACTIVE','INACTIVE') NOT NULL DEFAULT 'ACTIVE',
    created_at        TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    
    FOREIGN KEY (product_id) REFERENCES product(product_id)
);
```
**Why needed**: This is a proper catalog-level definition. "5GB storage at ₹50/GB" is defined here. `included_units` tells you how many free units come with a plan.

---

### 3. `Dunning_Schedule` Table (Missing!)

```sql
CREATE TABLE dunning_schedule (
    dunning_id        BIGINT          PRIMARY KEY AUTO_INCREMENT,
    invoice_id        BIGINT          NOT NULL,     -- FK → Invoice
    subscription_id   BIGINT          NOT NULL,     -- FK → Subscription
    attempt_count     INT             NOT NULL DEFAULT 0,
    max_attempts      INT             NOT NULL DEFAULT 3,
    next_retry_date   DATE            NOT NULL,
    status            ENUM('PENDING','IN_PROGRESS','RESOLVED','EXHAUSTED') NOT NULL,
    end_action        ENUM('CANCEL','HOLD') NOT NULL DEFAULT 'CANCEL',
    last_attempted_at TIMESTAMP       NULL,
    created_at        TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at        TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    
    FOREIGN KEY (invoice_id) REFERENCES invoice(invoice_id),
    FOREIGN KEY (subscription_id) REFERENCES subscription(subscription_id)
);
```
**Why needed**: US 09 requires retry strategies. Without this table, you can't track retry schedules, attempt counts, or next retry dates.

---

### 4. `Revenue_Snapshot` Table (Missing!)

```sql
CREATE TABLE revenue_snapshot (
    snapshot_id            BIGINT     PRIMARY KEY AUTO_INCREMENT,
    snapshot_date          DATE       NOT NULL UNIQUE,
    mrr_minor              BIGINT     NOT NULL,
    arr_minor              BIGINT     NOT NULL,
    arpu_minor             BIGINT     NOT NULL,
    active_customers       INT        NOT NULL,
    new_customers          INT        NOT NULL DEFAULT 0,
    churned_customers      INT        NOT NULL DEFAULT 0,
    gross_churn_percent    DECIMAL(5,2) NOT NULL,
    net_churn_percent      DECIMAL(5,2) NOT NULL,
    ltv_minor              BIGINT     NOT NULL DEFAULT 0,
    total_revenue_minor    BIGINT     NOT NULL,
    total_refunds_minor    BIGINT     NOT NULL DEFAULT 0,
    created_at             TIMESTAMP  NOT NULL DEFAULT CURRENT_TIMESTAMP
);
```
**Why needed**: US 07 requires MRR/ARR/Churn analytics. Daily snapshots enable historical trend charts without recomputing from raw data each time.

---

### 5. `Plan_Metered_Component` (Bridge table — NEW)

```sql
CREATE TABLE plan_metered_component (
    id               BIGINT     PRIMARY KEY AUTO_INCREMENT,
    plan_id          BIGINT     NOT NULL,          -- FK → Plan
    component_id     BIGINT     NOT NULL,          -- FK → Metered_Component
    included_units   INT        NOT NULL DEFAULT 0, -- free units for THIS plan
    
    FOREIGN KEY (plan_id) REFERENCES plan(plan_id),
    FOREIGN KEY (component_id) REFERENCES metered_component(component_id),
    UNIQUE (plan_id, component_id)
);
```
**Why needed**: Different plans offer different free quotas. Basic plan gets 5GB free, Pro gets 15GB free. This bridge table links plans to metered components with plan-specific free allowances.

---

## 📊 Complete Revised Schema Summary

### Final Table Count: 19 tables

| # | Table | Domain | Status |
|---|-------|--------|--------|
| 1 | `user` | Domain 1 | ✏️ Modified (password_hash, add role ENUM) |
| 2 | ~~`role`~~ | ~~Domain 1~~ | ❌ **DROP** (merge into User) |
| 3 | ~~`user_role`~~ | ~~Domain 1~~ | ❌ **DROP** (merge into User) |
| 4 | `customer` | Domain 1 | ✏️ Modified (add user_id FK, region, fix phone) |
| 5 | `product` | Domain 1 | ✏️ Minor fixes |
| 6 | `plan` | Domain 1 | ✏️ Modified (fix types, add proration_mode) |
| 7 | `add_on` | Domain 1 | 🆕 **NEW** |
| 8 | `metered_component` | Domain 1 | 🆕 **NEW** (replaces metered_item) |
| 9 | `plan_metered_component` | Domain 1 | 🆕 **NEW** |
| 10 | `subscription` | Domain 2 | ✏️ Modified (fix types, add timestamps) |
| 11 | `subscription_item` | Domain 2 | ✏️ Modified (fix types, add reference_id) |
| 12 | `invoice` | Domain 3 | ✏️ Modified (fix types, add invoice_number, idempotency_key) |
| 13 | `invoice_line_item` | Domain 3 | ✏️ Modified (add line_type, fix types) |
| 14 | `credit_note` | Domain 3 | ✏️ Minor fixes |
| 15 | `dunning_schedule` | Domain 3 | 🆕 **NEW** |
| 16 | `payment` | Domain 4 | ✏️ Modified (fix status enum, add idempotency_key) |
| 17 | `payment_method` | Domain 4 | ✏️ Modified (add token, card_brand, fix types) |
| 18 | `tax_rate` | Domain 4 | ✏️ Modified (fix column types) |
| 19 | `coupon` | Domain 4 | ✏️ Modified (fix types, add FOREVER) |
| 20 | `usage_record` | Domain 2 | ✏️ Modified (add timestamps, period tracking) |
| 21 | `notification` | Domain 5 | ✏️ Minor fixes |
| 22 | `audit_log` | Domain 5 | ✏️ Type fixes |
| 23 | `revenue_snapshot` | Domain 5 | 🆕 **NEW** |

**Net change**: 14 → 19 tables (+5 new, -2 dropped = net +3, but with replaced metered_item → metered_component)

---

## 🔄 Metered Billing Flow — How It All Maps Together

### Data Flow for Metered Charges

```
CATALOG SETUP (Admin)                     SUBSCRIPTION TIME (Customer)
┌─────────────────────┐                   ┌──────────────────────────────┐
│ Product             │                   │ Subscription                 │
│  └── Plan           │                   │  └── SubscriptionItem        │
│       └── Plan_     │                   │       (item_type = METERED,  │
│           Metered_  │──────────────────▶│        reference_id → comp)  │
│           Component │  "This plan       │                              │
│  └── Metered_       │   includes this   │  Usage_Record                │
│      Component      │   component"      │   (subscription_id,          │
│      (catalog def)  │                   │    component_id,             │
└─────────────────────┘                   │    quantity, recorded_at)    │
                                          └──────────────────────────────┘

BILLING TIME (Cron Job)
┌─────────────────────────────────────────────────────────────────────┐
│ 1. Get all active subscriptions due for renewal                     │
│ 2. For each subscription:                                           │
│    a. Calculate flat charges (base plan + add-ons)                  │
│    b. Aggregate usage_records for the billing period                │
│    c. Subtract included_units (from plan_metered_component)         │
│    d. Charge: (used_units - included_units) × price_per_unit        │
│    e. Generate invoice with line items for each charge type          │
│ 3. Apply tax (from tax_rate based on customer.region)               │
│ 4. Apply discount (from coupon if active)                           │
│ 5. Attempt payment                                                  │
└─────────────────────────────────────────────────────────────────────┘
```

### Example: Streaming Platform

```
Product: "StreamFlix"
├── Plan: "Basic"     → ₹199/mo, 5GB storage included
├── Plan: "Pro"       → ₹499/mo, 15GB storage included  
├── Plan: "Family"    → ₹799/mo, 50GB storage included
├── AddOn: "4K Quality"     → ₹99/mo
├── AddOn: "No Ads"         → ₹49/mo
└── Metered Component: "Extra Storage" → ₹10/GB/mo

Customer subscribes to "Pro" + "No Ads" + uses 22GB storage

Invoice Line Items:
┌────────────────────────────┬──────────┬────────────┬───────────┐
│ Description                │ Quantity │ Unit Price │ Amount    │
├────────────────────────────┼──────────┼────────────┼───────────┤
│ Pro Plan (Monthly)         │ 1        │ ₹499.00    │ ₹499.00   │
│ Add-on: No Ads             │ 1        │ ₹49.00     │ ₹49.00    │
│ Extra Storage (7 GB overage)│ 7       │ ₹10.00     │ ₹70.00    │
│ Subtotal                   │          │            │ ₹618.00   │
│ GST (18%)                  │          │            │ ₹111.24   │
│ Coupon: SAVE10 (-10%)      │          │            │ -₹61.80   │
│ Total                      │          │            │ ₹667.44   │
└────────────────────────────┴──────────┴────────────┴───────────┘
(22 GB used - 15 GB included in Pro = 7 GB overage × ₹10/GB = ₹70)
```

---

## 🗺️ Complete Entity Relationship Map

```
                            ┌──────────┐
                            │   User   │
                            │ (auth)   │
                            └────┬─────┘
                                 │ 1:0..1
                                 ▼
┌──────────┐    1:N    ┌────────────────┐    1:N    ┌───────────────┐
│ Product  │──────────▶│    Plan        │◀──────────│ Subscription  │
│          │           │                │           │               │
│          │──┐        └───────┬────────┘           │  customer_id──┼──▶ Customer
│          │  │    1:N         │                     │  plan_id──────┼──▶ Plan
│          │  │      ┌────────┘                     │  payment_     │
│          │  │      │ M:N                          │  method_id────┼──▶ PaymentMethod
└──────┬───┘  │      ▼                              └───────┬───────┘
       │      │  ┌────────────────────┐                     │ 1:N
       │      │  │ Plan_Metered_      │                     ▼
       │      │  │ Component          │             ┌───────────────┐
       │      │  └────────┬───────────┘             │ Subscription  │
       │ 1:N  │           │                         │ Item          │
       │      │           ▼                         └───────┬───────┘
       │      │  ┌────────────────────┐                     │
       │      │  │ Metered_Component  │◀────────────────────┘ (if METERED type)
       │      │  └────────┬───────────┘
       │      │           │ 1:N                     ┌───────────────┐
       │      │           ▼                    ┌───▶│ Invoice       │
       │      │  ┌────────────────────┐        │    │ Line Item     │
       │      │  │ Usage_Record       │        │    └───────────────┘
       │      │  │ (per subscription  │        │            ▲
       │      │  │  per component)    │        │            │ 1:N
       │      │  └────────────────────┘        │    ┌───────┴───────┐
       │      │                                │    │   Invoice     │
       │      └──▶ ┌──────────┐                │    │               │
       │           │  AddOn   │                │    │  customer_id──┼──▶ Customer
       │           └──────────┘                │    │  sub_id───────┼──▶ Subscription
       │                                       │    └───────┬───────┘
       │                                       │            │ 1:N
       ▼                                       │            ▼
  ┌──────────┐                                 │    ┌───────────────┐
  │ Customer │─────────────────────────────────┘    │   Payment     │
  │          │ 1:N                                  └───────────────┘
  │          │──────▶ PaymentMethod                         │
  │          │──────▶ Notification                          │ on failure
  └──────────┘                                              ▼
                                                    ┌───────────────┐
                                                    │  Dunning      │
                                                    │  Schedule     │
                                                    └───────────────┘
```

---

## 💡 Regarding the 6 New User Stories (US 10–15)

You mentioned the first 9 user stories are finalized and the new 6 are not. Here's the impact:

> [!IMPORTANT]
> **The schema changes above cover ALL 15 user stories.** The metered components (Metered_Component, Plan_Metered_Component, Usage_Record) are needed regardless of whether the new 6 are finalized, because metered billing is mentioned in the SRS scope under Catalog (US 03) and is foundational to any streaming billing system.

The 6 new user stories (US 10–15) don't add new tables — they primarily use existing tables:
- **US 10 (RBAC)** → Uses `User.role` column
- **US 11 (Invoice PDF)** → Uses `Invoice` + `InvoiceLineItem`
- **US 12 (Pause/Resume)** → Uses `Subscription.paused_from/paused_to`
- **US 13 (Audit Log)** → Uses `AuditLog` table
- **US 14 (Coupon at checkout)** → Uses `Coupon` table
- **US 15 (Notification prefs)** → Could add a `notification_preference` table, but toggles can also be stored as columns on Customer

---

## 📝 Summary of All Changes

### Tables to DROP (2)
- `role` — merge into User as ENUM
- `user_role` — merge into User as ENUM

### Tables to ADD (5)
- `add_on` — catalog definition for optional extras
- `metered_component` — catalog definition for usage-based charges (replaces broken `metered_item`)
- `plan_metered_component` — bridge table linking plans to their metered quotas
- `dunning_schedule` — retry tracking for failed payments
- `revenue_snapshot` — daily KPI snapshots for analytics

### Tables to MODIFY (All remaining 12)
Every existing table has at least one fix needed — see detailed table-by-table section above.

### Top 5 Most Critical Fixes
1. **`password VARCHAR(18)` → `password_hash VARCHAR(255)`** — Security critical
2. **All `NUMERIC(x,y)` money columns → `BIGINT`** — The entire point of minor units is to avoid decimals
3. **Add `user_id` FK to Customer** — Without this, auth and billing are disconnected
4. **Add `idempotency_key` to Invoice and Payment** — Without this, duplicate charges can occur
5. **Replace `Metered_Item` with proper `Metered_Component`** — Current design is broken

-- Additive operational schema for inventory, production, cash controls,
-- corrections, expenses, configuration, and offline synchronization.
-- Existing applied migrations are intentionally left untouched.

do $$
begin
  if not exists (select 1 from pg_type where typname = 'sync_state') then
    create type public.sync_state as enum ('pending_sync', 'syncing', 'synced', 'needs_review', 'rejected', 'failed');
  end if;
  if not exists (select 1 from pg_type where typname = 'correction_kind') then
    create type public.correction_kind as enum ('void', 'refund');
  end if;
end $$;

alter table public.shops add column if not exists active boolean not null default true;
alter table public.shops add column if not exists config_revision integer not null default 1;
alter table public.branches add column if not exists active boolean not null default true;

create table if not exists public.shop_settings (
  shop_id uuid primary key references public.shops(id) on delete cascade,
  tax_inclusive_enabled boolean not null default false,
  tax_rate_bps integer not null default 1200 check (tax_rate_bps between 0 and 10000),
  receipt_footer text not null default '',
  version integer not null default 1,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);

create table if not exists public.payment_methods (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  code text not null,
  name text not null,
  kind public.payment_kind not null,
  requires_reference boolean not null default false,
  active boolean not null default true,
  sort_order integer not null default 0,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (shop_id, code),
  unique (shop_id, name)
);

create table if not exists public.branch_product_settings (
  branch_id uuid not null references public.branches(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  available boolean not null default true,
  version integer not null default 1,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now(),
  primary key (branch_id, product_id)
);

alter table public.products add column if not exists expected_yield_quantity numeric(14,3) not null default 1 check (expected_yield_quantity > 0);
alter table public.products add column if not exists expected_yield_unit text not null default 'serving';
alter table public.products add column if not exists pieces smallint check (pieces is null or pieces > 0);
alter table public.products add column if not exists rice_included boolean not null default false;
alter table public.products add column if not exists retired_at timestamptz;

alter table public.product_options add column if not exists sort_order integer not null default 0;
alter table public.product_options add column if not exists version integer not null default 1;
alter table public.ingredients add column if not exists category text not null default 'other';
alter table public.ingredients add column if not exists version integer not null default 1;

create table if not exists public.product_option_recipes (
  id uuid primary key default gen_random_uuid(),
  option_id uuid not null references public.product_options(id) on delete cascade,
  ingredient_id uuid not null references public.ingredients(id) on delete restrict,
  quantity numeric(14,3) not null check (quantity > 0),
  unique (option_id, ingredient_id)
);

create table if not exists public.restocks (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references public.branches(id) on delete cascade,
  request_id uuid not null,
  supplier text,
  note text,
  total_cost_centavos integer not null default 0 check (total_cost_centavos >= 0),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  unique (branch_id, request_id)
);

create table if not exists public.restock_items (
  id uuid primary key default gen_random_uuid(),
  restock_id uuid not null references public.restocks(id) on delete cascade,
  ingredient_id uuid not null references public.ingredients(id) on delete restrict,
  quantity numeric(14,3) not null check (quantity > 0),
  unit_cost_centavos integer not null check (unit_cost_centavos >= 0),
  unique (restock_id, ingredient_id)
);

create table if not exists public.production_batches (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references public.branches(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete restrict,
  request_id uuid not null,
  expected_yield numeric(14,3) not null check (expected_yield > 0),
  actual_yield numeric(14,3) not null check (actual_yield >= 0),
  waste_quantity numeric(14,3) not null default 0 check (waste_quantity >= 0),
  waste_reason text,
  total_cost_centavos integer not null default 0 check (total_cost_centavos >= 0),
  cost_per_unit_centavos numeric(18,6) not null default 0 check (cost_per_unit_centavos >= 0),
  prepared_by uuid not null references auth.users(id),
  posted_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (branch_id, request_id)
);

create table if not exists public.production_batch_inputs (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.production_batches(id) on delete cascade,
  ingredient_id uuid not null references public.ingredients(id) on delete restrict,
  quantity numeric(14,3) not null check (quantity > 0),
  unit_cost_centavos numeric(18,6) not null default 0 check (unit_cost_centavos >= 0)
);

create table if not exists public.order_line_consumptions (
  id uuid primary key default gen_random_uuid(),
  order_line_id uuid not null references public.order_lines(id) on delete cascade,
  ingredient_id uuid references public.ingredients(id) on delete restrict,
  product_id uuid references public.products(id) on delete restrict,
  quantity numeric(14,3) not null check (quantity > 0),
  unit_cost_centavos numeric(18,6) not null default 0 check (unit_cost_centavos >= 0),
  source text not null default 'recipe' check (source in ('recipe', 'option', 'finished_goods')),
  check ((ingredient_id is null) <> (product_id is null))
);

create table if not exists public.order_line_options (
  id bigint generated always as identity primary key,
  order_line_id uuid not null references public.order_lines(id) on delete cascade,
  option_id uuid references public.product_options(id) on delete set null,
  option_name text not null,
  unit_cost_centavos numeric(18,6) not null default 0 check (unit_cost_centavos >= 0)
);

create table if not exists public.cash_movements (
  id uuid primary key default gen_random_uuid(),
  shift_id uuid not null references public.cash_shifts(id) on delete restrict,
  request_id uuid not null,
  kind text not null check (kind in ('payout', 'safe_drop')),
  amount_centavos integer not null check (amount_centavos > 0),
  created_by uuid not null references auth.users(id),
  approved_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  unique (request_id)
);

create table if not exists public.order_corrections (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete restrict,
  branch_id uuid not null references public.branches(id) on delete cascade,
  kind public.correction_kind not null,
  reason text not null check (char_length(trim(reason)) >= 3),
  status public.request_status not null default 'pending',
  requested_by uuid not null references auth.users(id),
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  review_note text,
  refund_method public.payment_kind,
  refund_reference text,
  refund_amount_centavos integer check (refund_amount_centavos is null or refund_amount_centavos >= 0),
  reversal_id uuid,
  created_at timestamptz not null default now()
);

create table if not exists public.order_reversals (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references public.orders(id) on delete restrict,
  correction_id uuid not null unique references public.order_corrections(id) on delete restrict,
  branch_id uuid not null references public.branches(id) on delete cascade,
  total_centavos integer not null check (total_centavos >= 0),
  cost_centavos integer not null default 0 check (cost_centavos >= 0),
  refund_method public.payment_kind not null,
  refund_reference text,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

alter table public.order_corrections
  drop constraint if exists order_corrections_reversal_id_fkey;
alter table public.order_corrections
  add constraint order_corrections_reversal_id_fkey
  foreign key (reversal_id) references public.order_reversals(id) on delete set null;

create table if not exists public.expenses (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references public.branches(id) on delete cascade,
  category text not null,
  description text not null,
  amount_centavos integer not null check (amount_centavos > 0),
  paid_from_cash boolean not null default false,
  cash_movement_id uuid references public.cash_movements(id) on delete restrict,
  spent_at timestamptz not null default now(),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  version integer not null default 1,
  unique (cash_movement_id)
);

alter table public.orders add column if not exists shift_id uuid references public.cash_shifts(id) on delete set null;
alter table public.orders add column if not exists subtotal_centavos integer not null default 0 check (subtotal_centavos >= 0);
alter table public.orders add column if not exists discount_centavos integer not null default 0 check (discount_centavos >= 0);
alter table public.orders add column if not exists discount_reason text;
alter table public.orders add column if not exists tax_centavos integer not null default 0 check (tax_centavos >= 0);
alter table public.orders add column if not exists tax_rate_bps integer not null default 0;
alter table public.orders add column if not exists tax_inclusive boolean not null default true;
alter table public.orders add column if not exists payment_method_id uuid references public.payment_methods(id) on delete set null;
alter table public.orders add column if not exists tendered_centavos integer check (tendered_centavos is null or tendered_centavos >= 0);
alter table public.orders add column if not exists change_centavos integer check (change_centavos is null or change_centavos >= 0);
alter table public.orders add column if not exists config_revision integer;
alter table public.orders add column if not exists offline_captured_at timestamptz;
alter table public.orders add column if not exists review_reason text;
alter table public.orders add column if not exists reviewed_by uuid references auth.users(id);
alter table public.orders add column if not exists reviewed_at timestamptz;
alter table public.orders add column if not exists updated_at timestamptz not null default now();

alter table public.order_lines add column if not exists line_subtotal_centavos integer not null default 0 check (line_subtotal_centavos >= 0);
alter table public.order_lines add column if not exists line_discount_centavos integer not null default 0 check (line_discount_centavos >= 0);
alter table public.order_lines add column if not exists line_tax_centavos integer not null default 0 check (line_tax_centavos >= 0);
alter table public.order_lines add column if not exists stock_model public.stock_model;
alter table public.order_lines add column if not exists cost_estimated boolean not null default false;

alter table public.payments add column if not exists payment_method_id uuid references public.payment_methods(id) on delete set null;
alter table public.payments add column if not exists tendered_centavos integer check (tendered_centavos is null or tendered_centavos >= 0);
alter table public.payments add column if not exists change_centavos integer check (change_centavos is null or change_centavos >= 0);

alter table public.cash_shifts add column if not exists status text not null default 'open';
alter table public.cash_shifts add column if not exists closed_by uuid references auth.users(id);
alter table public.cash_shifts add column if not exists expected_cash_centavos integer;
alter table public.cash_shifts add column if not exists over_short_centavos integer;
alter table public.cash_shifts add column if not exists note text;
alter table public.cash_shifts add column if not exists version integer not null default 1;
update public.cash_shifts set status = 'closed' where closed_at is not null and status = 'open';

alter table public.cash_movement_requests add column if not exists reviewed_by uuid references auth.users(id);
alter table public.cash_movement_requests add column if not exists reviewed_at timestamptz;
alter table public.cash_movement_requests add column if not exists review_note text;
alter table public.cash_movement_requests add column if not exists applied_movement_id uuid references public.cash_movements(id) on delete set null;
alter table public.cash_movement_requests add column if not exists request_id uuid;

alter table public.branch_devices add column if not exists last_seen_at timestamptz;
alter table public.branch_devices add column if not exists wipe_requested_at timestamptz;
alter table public.branch_devices add column if not exists revoked_by uuid references auth.users(id);
alter table public.branch_devices add column if not exists revoked_reason text;
alter table public.branch_devices add column if not exists version integer not null default 1;

alter table public.sync_requests add column if not exists sync_state public.sync_state not null default 'pending_sync';
alter table public.sync_requests add column if not exists branch_id uuid references public.branches(id) on delete cascade;
alter table public.sync_requests add column if not exists user_id uuid references auth.users(id) on delete cascade;
alter table public.sync_requests add column if not exists local_sequence bigint;
alter table public.sync_requests add column if not exists config_revision integer;
alter table public.sync_requests add column if not exists payload jsonb not null default '{}'::jsonb;
alter table public.sync_requests add column if not exists error_code text;
alter table public.sync_requests add column if not exists error_detail text;
alter table public.sync_requests add column if not exists updated_at timestamptz not null default now();

alter table public.audit_events add column if not exists branch_id uuid references public.branches(id) on delete set null;
alter table public.audit_events add column if not exists shop_id uuid references public.shops(id) on delete set null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'cash_shifts_status_check') then
    alter table public.cash_shifts add constraint cash_shifts_status_check check (status in ('open', 'closed'));
  end if;
end $$;

create unique index if not exists orders_branch_request_unique on public.orders(branch_id, request_id);
create unique index if not exists cash_shifts_one_open_cashier on public.cash_shifts(branch_id, cashier_id) where closed_at is null;
create unique index if not exists cash_movement_requests_request_unique on public.cash_movement_requests(shift_id, request_id) where request_id is not null;
create unique index if not exists sync_requests_device_sequence_unique on public.sync_requests(device_id, local_sequence) where local_sequence is not null;

create index if not exists orders_branch_created_idx on public.orders(branch_id, created_at desc);
create index if not exists orders_branch_status_created_idx on public.orders(branch_id, status, created_at desc);
create index if not exists orders_shift_idx on public.orders(shift_id) where shift_id is not null;
create index if not exists order_lines_order_idx on public.order_lines(order_id);
create index if not exists order_line_options_line_idx on public.order_line_options(order_line_id);
create index if not exists products_shop_active_idx on public.products(shop_id, active);
create index if not exists product_options_product_active_idx on public.product_options(product_id, active);
create index if not exists ingredients_shop_active_idx on public.ingredients(shop_id, active);
create index if not exists ingredient_balances_branch_low_idx on public.ingredient_balances(branch_id);
create index if not exists finished_goods_branch_idx on public.finished_goods_balances(branch_id);
create index if not exists inventory_movements_branch_kind_created_idx on public.inventory_movements(branch_id, kind, created_at desc);
create index if not exists restocks_branch_created_idx on public.restocks(branch_id, created_at desc);
create index if not exists production_batches_branch_created_idx on public.production_batches(branch_id, created_at desc);
create index if not exists cash_shifts_branch_opened_idx on public.cash_shifts(branch_id, opened_at desc);
create index if not exists cash_movement_requests_branch_status_idx on public.cash_movement_requests(shift_id, status);
create index if not exists order_corrections_branch_status_idx on public.order_corrections(branch_id, status, created_at desc);
create index if not exists expenses_branch_spent_idx on public.expenses(branch_id, spent_at desc);
create index if not exists sync_requests_branch_state_idx on public.sync_requests(branch_id, sync_state, created_at);
create index if not exists branch_devices_branch_idx on public.branch_devices(branch_id);
create index if not exists audit_events_branch_created_idx on public.audit_events(branch_id, created_at desc);

comment on table public.shop_settings is 'Per-shop inclusive-tax display and receipt configuration.';
comment on table public.payment_methods is 'Owner-managed payment methods per shop.';
comment on table public.production_batches is 'Posted production runs. Recipe quantities represent one batch.';
comment on table public.order_line_consumptions is 'Immutable per-line consumption snapshots used for exact reversal.';
comment on table public.order_line_options is 'Normalized selected option snapshot for reporting and reversal.';

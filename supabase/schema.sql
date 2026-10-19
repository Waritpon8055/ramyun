-- รันไฟล์นี้ครั้งเดียวใน Supabase: SQL Editor > New query > วางทั้งไฟล์ > Run

-- ข้อมูลทั้งหมดของร้านอยู่ในตารางเดียว
-- path เช่น config/shop, members/all, days/2026-10-19, images/<รหัสสินค้า>
create table if not exists public.docs (
  path       text primary key,
  data       jsonb not null,
  updated_at timestamptz not null default now()
);

-- อีเมลที่มีสิทธิ์ใช้ระบบ (เจ้าของร้าน)
create table if not exists public.shop_owners (
  email text primary key
);

create or replace function public.is_shop_owner()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.shop_owners where lower(email) = lower(auth.jwt() ->> 'email'));
$$;

alter table public.docs enable row level security;
alter table public.shop_owners enable row level security;   -- ไม่มี policy = เปิดอ่านจากเว็บไม่ได้

drop policy if exists "owner can read"   on public.docs;
drop policy if exists "owner can insert" on public.docs;
drop policy if exists "owner can update" on public.docs;
drop policy if exists "owner can delete" on public.docs;
create policy "owner can read"   on public.docs for select to authenticated using (public.is_shop_owner());
create policy "owner can insert" on public.docs for insert to authenticated with check (public.is_shop_owner());
create policy "owner can update" on public.docs for update to authenticated using (public.is_shop_owner()) with check (public.is_shop_owner());
create policy "owner can delete" on public.docs for delete to authenticated using (public.is_shop_owner());

-- ให้หลายเครื่องเห็นการเปลี่ยนแปลงทันที
alter publication supabase_realtime add table public.docs;

-- ใส่อีเมลเจ้าของร้าน (แก้เป็นอีเมลจริง แล้วรันบรรทัดนี้)
-- insert into public.shop_owners (email) values ('owner@example.com');

-- รวมฟิลด์และบวกลบตัวนับ (สต็อก แต้ม) ในคำสั่งเดียว หลายเครื่องบันทึกพร้อมกันได้โดยไม่ทับกัน
create or replace function public.docs_apply(p_path text, p_patch jsonb, p_incr jsonb)
returns jsonb language plpgsql security invoker set search_path = public as $$
declare cur jsonb; k text; v numeric;
begin
  insert into public.docs (path, data) values (p_path, '{}'::jsonb) on conflict (path) do nothing;
  select data into cur from public.docs where path = p_path for update;
  if cur is null then raise exception 'not allowed' using errcode = '42501'; end if;
  cur := cur || coalesce(p_patch, '{}'::jsonb);
  for k, v in select key, value::numeric from jsonb_each_text(coalesce(p_incr, '{}'::jsonb)) loop
    cur := jsonb_set(cur, array[k], to_jsonb(greatest(0, coalesce((cur ->> k)::numeric, 0) + v)));
  end loop;
  update public.docs set data = cur, updated_at = now() where path = p_path;
  return cur;
end $$;
revoke execute on function public.docs_apply(text, jsonb, jsonb) from public, anon;
grant execute on function public.docs_apply(text, jsonb, jsonb) to authenticated;

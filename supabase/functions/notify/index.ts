// Sends web push notifications to the group.
// Called by the app (with the signed-in person's token) after they post a meal or like one.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const clip = (s: unknown, n: number) => String(s ?? "").slice(0, n);

type Msg = { title: string; body: string };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  // Who is asking?
  const asUser = createClient(url, anon, { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } });
  const { data: who } = await asUser.auth.getUser();
  const caller = who?.user;
  if (!caller) return json({ error: "Not signed in" }, 401);

  const admin = createClient(url, service, { auth: { persistSession: false } });

  // Only people in a group can send, and only to people they share a group with.
  const callerEmail = String(caller.email).toLowerCase();
  const { data: gm } = await admin.from("group_members").select("group_id,email");
  const myGroups = new Set((gm ?? []).filter((r) => r.email === callerEmail).map((r) => r.group_id));
  if (!myGroups.size) return json({ error: "Not in a group" }, 403);
  const memberEmails = new Set((gm ?? []).filter((r) => myGroups.has(r.group_id)).map((r) => String(r.email).toLowerCase()));

  let input: Record<string, unknown>;
  try { input = await req.json(); } catch { return json({ error: "Bad request" }, 400); }
  const type = String(input.type);
  const mealId = String(input.meal_id ?? "");
  const main: Msg = { title: clip(input.title, 80), body: clip(input.body, 180) };
  const alt = input.alt && typeof input.alt === "object" ? { title: clip((input.alt as Msg).title, 80), body: clip((input.alt as Msg).body, 180) } : null;
  if (!["meal", "done", "like"].includes(type) || !mealId || !main.title) return json({ error: "Bad request" }, 400);

  const { data: meal } = await admin.from("meals").select("id,user_id").eq("id", mealId).maybeSingle();
  if (!meal) return json({ error: "Meal not found" }, 404);

  // Check the caller really did the thing they're announcing.
  if ((type === "meal" || type === "done") && meal.user_id !== caller.id) return json({ error: "Not your meal" }, 403);
  if (type === "like") {
    if (meal.user_id === caller.id) return json({ sent: 0 });
    const { data: like } = await admin.from("likes").select("meal_id").eq("meal_id", mealId).eq("user_id", caller.id).maybeSingle();
    if (!like) return json({ error: "No like found" }, 403);
  }

  // Map account ids to emails: only people sharing a group with the sender.
  const { data: list } = await admin.auth.admin.listUsers({ perPage: 1000 });
  const inGroup = new Set((list?.users ?? []).filter((u) => memberEmails.has(String(u.email).toLowerCase())).map((u) => u.id));

  const { data: people } = await admin.from("profiles").select("id,notify");
  const prefs: Record<string, Record<string, boolean>> = {};
  (people ?? []).forEach((p) => (prefs[p.id] = p.notify ?? {}));
  const wants = (uid: string, key: string) => prefs[uid]?.[key] !== false;

  // Decide who gets which message.
  const plan = new Map<string, Msg>();
  if (type === "like") {
    if (inGroup.has(meal.user_id) && wants(meal.user_id, "likes")) plan.set(meal.user_id, main);
  } else {
    for (const uid of inGroup) {
      if (uid === caller.id) continue;
      if (type === "done" && wants(uid, "done")) plan.set(uid, main);
      else if (wants(uid, "meals")) plan.set(uid, type === "done" && alt ? alt : main);
    }
  }
  if (!plan.size) return json({ sent: 0 });

  const { data: cfg } = await admin.from("push_config").select("*").eq("id", 1).single();
  webpush.setVapidDetails(cfg.subject, cfg.vapid_public, cfg.vapid_private);

  const { data: subs } = await admin.from("push_subscriptions").select("*").in("user_id", Array.from(plan.keys()));
  const link = "/?meal=" + encodeURIComponent(mealId);
  let sent = 0;
  const gone: string[] = [];
  await Promise.all((subs ?? []).map(async (s) => {
    const msg = plan.get(s.user_id)!;
    try {
      await webpush.sendNotification(
        { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
        JSON.stringify({ title: msg.title, body: msg.body, url: link, tag: type + "-" + mealId }),
        { TTL: 60 * 60 * 24 },
      );
      sent++;
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) gone.push(s.endpoint);   // that phone turned notifications off
      else console.error("push failed", code, String(e).slice(0, 200));
    }
  }));
  if (gone.length) await admin.from("push_subscriptions").delete().in("endpoint", gone);
  return json({ sent, removed: gone.length });
});

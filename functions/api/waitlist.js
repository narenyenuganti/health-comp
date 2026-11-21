export async function onRequestPost({ request, env }) {
  const form = await request.formData();
  if (form.get("_honey")) return Response.json({ ok: true });
  const email = String(form.get("email") ?? "").trim();
  if (email.length > 254 || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
    return Response.json({ error: "Enter a valid email address." }, { status: 400 });
  }
  const sent = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      from: "HealthComp <onboarding@resend.dev>",
      to: "yrnaren1@gmail.com",
      subject: `Waitlist signup: ${email}`,
      text: `${email} joined the HealthComp waitlist.`,
    }),
  });
  if (!sent.ok) {
    console.error("Resend", sent.status, await sent.text());
    return Response.json({ error: "Couldn’t sign you up. Try again in a minute." }, { status: 502 });
  }
  return Response.json({ ok: true });
}

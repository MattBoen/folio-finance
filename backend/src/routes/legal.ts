import { Hono } from "hono";

// Public privacy policy page. Content mirrors Folio-Privacy-Policy.pdf; update both together.
const legal = new Hono();

const privacyHtml = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>Folio Privacy Policy</title>
<style>
:root{--bg:#f5f6fa;--card:#fff;--ink:#1d1d1f;--muted:#6e6e73;--line:#e1e4ea;--blue:#2f6fed;--soft:#f0f2f7}
@media (prefers-color-scheme:dark){:root{--bg:#0e0f13;--card:#1a1c22;--ink:#f2f2f5;--muted:#a1a1a8;--line:#2b2e37;--blue:#6b9bff;--soft:#22252d}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.6 -apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",Arial,sans-serif;-webkit-font-smoothing:antialiased}
main{max-width:760px;margin:0 auto;padding:28px 18px 64px}
header{margin-bottom:8px}
.brand{font-weight:700;letter-spacing:.06em;font-size:13px;color:var(--blue)}
h1{font-size:34px;line-height:1.15;margin:6px 0 6px;letter-spacing:-.02em}
.sub{color:var(--muted);margin:0 0 6px}
h2{font-size:20px;margin:32px 0 8px;letter-spacing:-.01em}
p,li{margin:0 0 10px}
ul{padding-left:22px;margin:0 0 10px}
a{color:var(--blue)}
.tw{overflow-x:auto;margin:6px 0 14px;border:1px solid var(--line);border-radius:12px;background:var(--card)}
table{border-collapse:collapse;width:100%;min-width:520px;font-size:14.5px}
th,td{text-align:left;vertical-align:top;padding:10px 12px;border-bottom:1px solid var(--line)}
th{background:var(--soft);font-weight:600}
tr:last-child td{border-bottom:0}
footer{margin-top:40px;color:var(--muted);font-size:13px}
</style>
</head>
<body>
<main>
<header>
<div class="brand">FOLIO FINANCE</div>
<h1>Privacy Policy</h1>
<p class="sub">Version 1.1 &middot; Effective October 28, 2026</p>
</header>
<h2>1. Who we are</h2>
<p>Folio Finance ("Folio", "we", "us") makes a personal finance app for iPhone that brings your accounts, spending, budget, and net worth into one place. This policy explains what information we collect, how we use and share it, how long we keep it, and the choices you have.</p>
<p>Questions or requests: <a href="mailto:folio.finance.app@gmail.com">folio.finance.app@gmail.com</a>.</p>
<h2>2. Information we collect</h2>
<div class="tw"><table><thead><tr><th>Type</th><th>What it includes</th><th>Where it comes from</th></tr></thead><tbody><tr><td>Account information</td><td>Your email address and a password. We store only a one-way hash of your password, never the password itself.</td><td>You, when you sign up (Continue creates your account after you confirm)</td></tr><tr><td>Financial account data</td><td>Institution name, account names, types and last digits, balances, transactions, and, where your accounts provide them, investment and loan or credit details.</td><td>Plaid, only after you choose to connect an account and authorize it</td></tr><tr><td>Information you enter</td><td>Manual accounts and balances, transactions, categories, budgets, income, and your age if you choose to add it.</td><td>You</td></tr><tr><td>Vehicle information</td><td>VIN, mileage, and an estimated value.</td><td>You, plus a value estimate we look up</td></tr><tr><td>Questions you ask Folio (optional)</td><td>Only if you turn on Ask Folio: the question you type. We do not store the question or the answer; we keep only a per-day count of questions to enforce a daily limit, for up to 30 days.</td><td>You</td></tr><tr><td>Technical information</td><td>App version, device type and iOS version, error reports, and your IP address in server request logs (used for security and abuse prevention).</td><td>Your device and our servers</td></tr></tbody></table></div>
<p>We <b>never</b> receive or store your bank username or password. You sign in to your bank inside Plaid's secure connection screen. If you choose to save your Folio login in the iOS Passwords app, it is stored by Apple on your device and iCloud Keychain, not by Folio.</p>
<h2>3. How we use your information</h2>
<ul><li>To provide the app: showing your accounts, spending, net worth, budgets, and insights.</li><li>To keep your account and data secure, prevent fraud and abuse, and troubleshoot problems.</li><li>To respond to your questions and requests.</li><li>To meet legal obligations.</li><li>To improve reliability and the product, using aggregated or de-identified information where possible.</li></ul>
<p><b>We do not sell your personal information, and we do not share it for advertising or use it to build advertising profiles.</b></p>
<h2>4. Who we share information with</h2>
<p>We share information only with service providers that help us run Folio, and only as needed for that purpose:</p>
<div class="tw"><table><thead><tr><th>Provider</th><th>Why</th><th>What they receive</th></tr></thead><tbody><tr><td>Plaid Inc.</td><td>Connects your accounts and retrieves the data you authorize</td><td>Your connection choices and credentials entered on Plaid's screens; we receive the data you authorize. Plaid's handling is described in its <a href="https://plaid.com/legal/#end-user-privacy-policy">End User Privacy Policy</a>.</td></tr><tr><td>Hosting provider (Render)</td><td>Runs our servers and database in the United States</td><td>The data we store, encrypted in transit and at rest</td></tr><tr><td>Vehicle data services</td><td>Identify your vehicle from its VIN and estimate its value</td><td>VIN and mileage only, not your name or account data</td></tr><tr><td>Anthropic, PBC (only if you turn on Ask Folio)</td><td>Writes the answer to a question you ask in Ask Folio</td><td>Your question and only the specific figures needed to answer it (for example balances, budget amounts, spending totals, merchant names and dates, investment totals). Not sent: your name, email, bank credentials, Plaid tokens, or account numbers. Under Anthropic's commercial API terms, inputs are not used to train its models by default.</td></tr><tr><td>Apple</td><td>App distribution and the iOS Passwords app if you choose to save your login</td><td>App installation data under Apple's terms; no financial data</td></tr></tbody></table></div>
<p>We may also disclose information if required by law or to protect rights, safety, or security, or as part of a merger or sale of the business (in which case we will tell you and this policy will continue to protect your data).</p>
<h2>5. Your consent and Plaid</h2>
<p>We ask for your permission before connecting any financial account. During setup you see a screen explaining what Folio and Plaid will access, and you must tap <b>Agree and continue</b>. Plaid then shows its own consent screen where you choose the accounts to share.</p>
<p><b>Withdrawing consent:</b> you can disconnect any account in the app under Accounts, which stops data collection and removes that connection's data from Folio. You can also review and revoke connections with Plaid at <a href="https://my.plaid.com">my.plaid.com</a>.</p>
<h2>6. Ask Folio (optional AI assistant)</h2>
<p>Ask Folio is <b>off by default</b>. Before it turns on, the app shows a notice explaining how it works, and you choose whether to turn it on. You can turn it off at any time in the Profile menu.</p>
<ul><li>When you ask a question, our server sends the question and only the specific figures needed to answer it (for example balances, budget amounts, spending totals, merchant names and dates, and investment totals) to Anthropic's API, which uses the Claude model to write the answer.</li><li>We do <b>not</b> send your name, email address, bank credentials, Plaid tokens, or account numbers.</li><li>We do <b>not</b> store your questions or the answers. We keep only a per-day count of questions to enforce a daily limit, for up to 30 days.</li><li>Anthropic acts as our service provider. Under its commercial API terms, inputs are not used to train its models by default.</li><li>Ask Folio never changes anything on its own. If you ask it to change something (for example, raise a budget), it shows you the change and applies it only after you tap <b>Confirm</b>.</li><li>Answers are general information based on your data, not financial, tax, or investment advice, and can be wrong. Check important numbers in the app.</li></ul>
<h2>7. How long we keep information, and deleting it</h2>
<ul><li>We keep your information while you have an account and delete it when you ask us to or when it is no longer needed.</li><li><b>Delete your account in the app</b> (Profile, Delete account). This tells Plaid to remove your connections and permanently deletes your account and all data we hold about you.</li><li><b>Disconnect an account</b> to remove its Plaid connection and the data imported from it.</li><li>Or email <a href="mailto:folio.finance.app@gmail.com">folio.finance.app@gmail.com</a> from the address on your account; we complete requests within 30 days.</li><li>Questions and answers in Ask Folio are not stored; the per-day question counter is kept up to 30 days.</li><li>Deleted data can remain in secure backups for a short period, up to 35 days, until the backups expire.</li><li>Accounts that are unused for 24 months may be deleted after we email you.</li><li>We may keep limited records where the law requires or to resolve disputes and prevent fraud.</li></ul>
<h2>8. How we protect your information</h2>
<ul><li>Encryption in transit (TLS 1.2 or higher) and at rest; Plaid access tokens are additionally encrypted before storage.</li><li>Passwords are stored only as salted one-way hashes.</li><li>Each customer can reach only their own data; access to our systems is limited to the people who need it and protected by multi-factor authentication.</li><li>A privacy cover that hides balances in the iOS app switcher.</li><li>A documented information security program with regular reviews and an incident response plan. No system is perfectly secure, but we work to protect your data and will notify you if a breach affects it.</li></ul>
<h2>9. Your rights and choices</h2>
<p>Depending on where you live, you can ask us to tell you what personal information we hold about you, give you a copy, correct it, delete it, or stop using it. You can disconnect accounts and delete your account any time in the app, and you can email us for anything else. We may need to verify it is you before acting, and we will not treat you differently for exercising your rights.</p>
<p><b>California and other US states:</b> we do not sell or share personal information as those terms are defined in state privacy laws, so there is nothing to opt out of. If we decline a request you can appeal by replying to our response, and you may contact your state attorney general.</p>
<p>We respond to requests within 30 days, or tell you if we need more time as the law allows.</p>
<h2>10. Children</h2>
<p>Folio is for people 18 and older. We do not knowingly collect information from anyone under 18. If you believe a child has given us information, email us and we will delete it.</p>
<h2>11. Where your information is processed</h2>
<p>Folio is operated from the United States and your information is processed and stored in the United States.</p>
<h2>12. Changes to this policy</h2>
<p>If we make material changes we will notify you in the app or by email before they take effect, and update the date below.</p>
<h2>13. Version history</h2>
<div class="tw"><table><thead><tr><th>Version</th><th>Date</th><th>Change</th></tr></thead><tbody><tr><td>1.1</td><td>October 28, 2026</td><td>Added the optional Ask Folio assistant and Anthropic as a service provider; updated how sign-in and the iOS Passwords app are described; removed statements about an app lock.</td></tr><tr><td>1.0</td><td>October 27, 2026</td><td>First version.</td></tr></tbody></table></div>
<h2>14. Contact us</h2>
<p>Folio Finance, <a href="mailto:folio.finance.app@gmail.com">folio.finance.app@gmail.com</a>. Last updated October 28, 2026.</p>
<footer>Questions? <a href="mailto:folio.finance.app@gmail.com">folio.finance.app@gmail.com</a></footer>
</main>
</body>
</html>
`;

legal.get("/privacy", (c) => {
  c.header("Cache-Control", "public, max-age=3600");
  return c.html(privacyHtml);
});

export { legal };

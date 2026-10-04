# DLP Policy — `Malaysian-NRIC-Detection`

A Microsoft Purview DLP policy that detects Malaysian NRIC/IC numbers (`YYMMDD-PB-####`) moving
through Exchange email and sitting in SharePoint / OneDrive. Built, deployed, and tested against
a live tenant.

**Scope note:** this is the Purview/data-protection half of the governance work in this repo. It
does not touch `detector.py` or the provisioning script — see
[the closing section](#where-this-sits-in-the-project) for how the pieces line up.

---

## What it detects

| Setting | Value |
|---|---|
| Policy | `Malaysian-NRIC-Detection` |
| Rule | `Detect-Malaysian-NRIC` (one rule) |
| Sensitive info type | **Malaysia Identity Card Number** (Purview built-in) |
| Instance count / confidence | Defaults |
| Locations | Exchange email, SharePoint sites, OneDrive accounts |

The format it matches is `YYMMDD-PB-####` — date of birth, place-of-birth code, then a four-digit
serial. The built-in SIT does the pattern work, so there is no custom regex to maintain and no
custom confidence tuning. Using the built-in type was deliberate: it is the thing Microsoft
keeps current, and a hand-rolled regex for NRIC is the kind of asset that rots quietly.

### Conditions and actions

**Condition:** content contains the sensitive info type `Malaysia Identity Card Number`.

**Actions:**

1. **User notifications — on.** The sender sees a policy tip, and receives an email notification
   after the fact.
2. **Incident report — on.** Admins are alerted on a rule match, so there is a record on the
   security side rather than only on the user's side.

Both halves matter. The notification is the user-facing feedback loop; the incident report is
what makes the policy useful to whoever is actually responsible for the data.

---

## Why NRIC, and why this matters

Malaysia's **Personal Data Protection Act (PDPA) 2010** treats NRIC numbers as personal data. The
Act puts obligations on how an organisation handles that data — and every one of those
obligations assumes you already know *where the data is*.

That is the gap this policy fills. Before you can argue you are complying with PDPA's
data-protection principles, you need visibility into NRIC numbers flowing out through email and
accumulating in SharePoint document libraries. A DLP policy is the cheapest way to get that
visibility: it tells you the volume and the paths, which is the input to every decision that
comes after.

---

## Tested and confirmed working

I sent a test email containing a fake-but-correctly-formatted NRIC number. Outlook flagged it and
the sender received the automated notification:

> Your email message conflicts with a policy in your organization. Issues: Message contains the
> following sensitive information: Malaysia Identity Card Number.

![Outlook notification showing the DLP policy match on a test email containing an NRIC number](screenshots/dlp-notification-email.png)

*Sender-side notification from the `Detect-Malaysian-NRIC` rule firing on a test email.*

The SIT matched on the first try with default settings — no tuning needed for a
correctly-formatted number.

---

## The limitation: this is a detective control, not a preventive one

Worth being blunt about, because it is the difference between a policy that looks good in a
screenshot and one that actually stops a leak.

**As configured, the policy notifies and logs — but the email still sends.** The sender gets told
they did something wrong *after* the message is already in the recipient's inbox. Nothing is
blocked. The NRIC number has already left the organisation by the time anyone is notified.

That is a **detective** control: it gives you detection and an audit trail. It does not give you
prevention.

### What a preventive version looks like

Swap the action for **Restrict access or encrypt the content**, with Exchange set to **Block**.
Then:

- Delivery is stopped before the recipient sees anything
- The sender gets a non-delivery report (NDR) instead of a notification
- The data never leaves

Same detection logic, same SIT, same rule condition — only the action changes.

### Why I built the notify version anyway

For demo visibility. A blocking policy produces an NDR and an empty inbox; a notifying policy
produces the notification above, which is the thing you can actually show someone. For a
portfolio lab that tradeoff is the right one.

**What I'd change for production:** block, not notify. A policy that detects PDPA-relevant data
leaving the organisation and then lets it leave is a reporting tool, not a control. The notify
configuration is a reasonable *first* deployment stage — run it to learn your false-positive rate
and find the legitimate business workflows that handle NRIC numbers — but it is a staging step,
not a destination. Once you know what the policy catches, you turn on Block.

---

## Where this sits in the project

This repo's **Identity Automation & Governance** work is in two halves:

1. **Entra ID detection lab** — `detector.py` and the KQL in `queries/`: brute-force and
   impossible-travel sign-in detection at the identity layer.
2. **This policy, plus the PowerShell provisioning automation**
   ([`docs/bulk-user-provisioning.md`](bulk-user-provisioning.md)) — the governance and
   data-protection side: provisioning identities correctly on the way in, and knowing where
   regulated personal data goes once those identities start using it.

Detection without governance tells you about attacks and nothing about your own data. This is the
other half.

# Recipient-bound invitations

Status: implemented locally; release qualification in progress; not deployed.

## User contract

- Choose an existing HealthComp account before creating an invitation. Only that
  account can accept it. A display name is not an identity.
- One unaccepted outgoing invitation per sender/recipient pair, not one total per
  sender. Different recipients remain independent.
- Invitations expire exactly 24 hours after creation. An expired invitation
  cannot be accepted and does not prevent a new invitation to that recipient.
- Retries of the same request remain idempotent. Concurrent requests cannot
  create duplicate pending invitations. Changing the recipient is a new request.
- Long recipient names wrap without truncation, including at accessibility sizes.

## Private account selection

Account exposes a shareable HealthComp account code: the existing random profile
UUID, not an Apple identifier or email. The creator pastes the exact code and
confirms the returned display name before creating a link. Authenticated exact-code
resolution returns only the profile ID and display name of an active other account;
there is no prefix search, email lookup, directory, or access to its history.

## Migration and compatibility

Use a new forward migration; never change historical migrations. Existing unnamed,
unaccepted invitations cannot safely be assigned a recipient, so expire them in
place. Preserve accepted competitions, schedules, scores and completed history.
Close older recipient-free creation RPCs rather than leaving a bearer-only bypass.
Ship the new RPC, Edge Function and app as a coordinated change. Older apps cannot
create new unnamed invitations after migration; existing accepted competitions
continue to work.

Pending recipient membership is visible to the creator but is not accepted
membership: it must not grant the chosen recipient competition/history access
before they open and accept the link. Expiry and duplicate checks run on the server.

## Verification interfaces

Use the established create/claim RPCs, HTTP handlers, client wire contracts, feature
actions and rendered app flow. Verify exact-recipient acceptance, wrong-account
rejection, same-request retry, concurrent duplicate creation, separate recipients,
24-hour boundary, stale invitation replacement, participant isolation, migration
preservation, and long-name/large-text rendering. Use synthetic local accounts only.

No phone, hosted migration/deployment, account switching, production action or new
live competition is part of source implementation and local qualification.

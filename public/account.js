// Accounts: registration, username-or-email sign-in, password reset, guest (anonymous) upgrade.
// Uses Supabase Auth only; there is no custom password store. Credentials are never logged or stored here.
import { $, text } from './ui.js?v=1.0.0';
import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from './online-config.js';

const GENERIC = 'Those sign-in details did not match. Check them and try again.';
const USERNAME = /^[a-z0-9_]{3,20}$/;

export function createAccount({ db, rpc, onChange, getRememberedRoom }) {
  const account = { status: 'loading', user: null, profile: null, recovering: false };
  const say = (message) => text('homeFeedback', message);
  const redirectTo = () => location.origin + location.pathname;
  let busy = false;

  function setBusy(value) { busy = value; document.querySelectorAll('#homeCard button, #homeCard input').forEach((el) => { el.disabled = value; }); }
  async function guarded(work) {
    if (busy) return; setBusy(true);
    try { await work(); } catch (e) { say(e?.message || 'Something went wrong. Please try again.'); } finally { setBusy(false); }
  }

  // status: signedOut | guest (legacy anonymous) | needsProfile | ready | recovery | backendPending
  async function refresh() {
    const { data } = await db.auth.getSession();
    const user = data?.session?.user || null;
    account.user = user; account.profile = null;
    if (account.recovering && user) account.status = 'recovery';
    else if (!user) account.status = 'signedOut';
    else if (user.is_anonymous) account.status = 'guest';
    else {
      try {
        account.profile = await rpc('tt_profile', {});
        account.status = account.profile?.hasProfile ? 'ready' : 'needsProfile';
      } catch (e) {
        account.status = e?.code === 'PGRST202' ? 'backendPending' : 'needsProfile';
      }
    }
    render(); onChange(account);
    return account;
  }

  function showTab(register) {
    $('signInForm').hidden = register; $('registerForm').hidden = !register; $('resetForm').hidden = true;
    $('tabSignIn').setAttribute('aria-selected', String(!register)); $('tabRegister').setAttribute('aria-selected', String(register));
  }

  function render() {
    const s = account.status, guest = s === 'guest', remembered = getRememberedRoom();
    $('authPanel').hidden = !(s === 'signedOut' || guest);
    $('newPasswordForm').hidden = s !== 'recovery';
    $('profileForm').hidden = s !== 'needsProfile';
    $('entryPanel').hidden = s !== 'ready';
    $('guestPanel').hidden = !guest;
    $('guestUpgradeNote').hidden = !guest;
    $('carryWrap').hidden = !(guest && remembered); if (remembered) text('carryRoom', remembered);
    if (s === 'needsProfile') {
      const meta = account.user?.user_metadata || {};
      if (!$('profileUsername').value) $('profileUsername').value = meta.username || '';
      if (!$('profileDisplay').value) $('profileDisplay').value = meta.display_name || '';
      // A guest who has just confirmed an email still needs a password before the account is usable elsewhere.
      $('profilePasswordWrap').hidden = !meta.needs_password; $('profilePassword').required = !!meta.needs_password;
    }
    if (s === 'ready') text('whoAmI', `${account.profile.displayName} (@${account.profile.username})`);
    if (s === 'backendPending') say('The server has not been upgraded for accounts yet (migration 020 onward). Existing rooms still open below.');
    if (s === 'loading') say('Connecting…');
  }

  async function saveProfile(username, display) {
    account.profile = await rpc('tt_profile_save', { p_username: username, p_display: display });
  }

  async function signIn(identifier, password) {
    const id = identifier.trim().toLowerCase();
    if (id.includes('@')) {
      const { error } = await db.auth.signInWithPassword({ email: id, password });
      if (error) throw Error(/confirm/i.test(error.message) ? 'Confirm your email first: open the link we sent, then sign in.' : GENERIC);
      return;
    }
    if (!USERNAME.test(id)) throw Error(GENERIC);
    // Usernames are resolved on the server; the browser never receives an email address.
    let response;
    try {
      response = await fetch(`${SUPABASE_URL}/functions/v1/tt-login`, { method: 'POST', cache: 'no-store',
        headers: { 'Content-Type': 'application/json', apikey: SUPABASE_PUBLISHABLE_KEY }, body: JSON.stringify({ identifier: id, password }) });
    } catch { throw Error('Could not reach the sign-in service. Check your connection, or sign in with your email.'); }
    if (response.status === 404) throw Error('Username sign-in is not set up on this server yet. Sign in with your email instead.');
    const body = await response.json().catch(() => ({}));
    if (!response.ok || !body.access_token) throw Error(response.status === 429 ? body.error : response.status === 403 || response.status === 503 ? 'Username sign-in is unavailable here right now. Sign in with your email instead.' : GENERIC);
    const { error } = await db.auth.setSession({ access_token: body.access_token, refresh_token: body.refresh_token });
    if (error) throw Error(GENERIC);
  }

  $('tabSignIn').onclick = () => showTab(false); $('tabRegister').onclick = () => showTab(true);
  $('showReset').onclick = () => { $('signInForm').hidden = true; $('resetForm').hidden = false; $('resetEmail').focus(); };
  $('cancelReset').onclick = () => showTab(false);

  $('signInForm').onsubmit = (e) => { e.preventDefault(); guarded(async () => {
    const guest = account.status === 'guest', room = getRememberedRoom(), carry = guest && room && $('carrySeat').checked;
    let token = null;
    if (carry) {
      // Explicit transfer: the guest proves ownership by minting a fresh recovery code, which the
      // account then redeems. Nothing is merged on the strength of a name.
      token = Array.from(crypto.getRandomValues(new Uint8Array(32)), (b) => b.toString(16).padStart(2, '0')).join('');
      await rpc('tt_save_recovery', { p_code: room, p_token: token });
    }
    await signIn($('signInId').value, $('signInPassword').value);
    $('signInPassword').value = '';
    await refresh();
    if (token && account.status === 'ready') {
      try {
        const moved = await rpc('tt_recover', { p_code: room, p_token: token });
        say(moved?.error ? 'Signed in, but the guest role could not be moved: ' + moved.error : 'Signed in. Your role in that room now belongs to this account.');
      } catch (err) { say('Signed in, but the guest role was not moved: ' + (err.message || 'unknown reason') + ' Its recovery code was replaced; create a new one from that identity if you still can.'); }
    } else if (token) say('Signed in. Finish your profile, then restore your earlier role with its recovery code.');
    else say('');
  }); };

  $('registerForm').onsubmit = (e) => { e.preventDefault(); guarded(async () => {
    const email = $('regEmail').value.trim().toLowerCase(), username = $('regUsername').value.trim().toLowerCase(), display = $('regDisplay').value.trim(), password = $('regPassword').value;
    if (!USERNAME.test(username)) throw Error('Usernames use 3–20 letters, numbers or underscores.');
    if (password.length < 8) throw Error('Use a password of at least 8 characters.');
    if (account.status === 'guest') {
      // Upgrade in place: the user id (and so every seat, image, proposal and message) is unchanged.
      const { error } = await db.auth.updateUser({ email, data: { username, display_name: display, needs_password: true } });
      if (error) throw Error(/already|registered|exists/i.test(error.message) ? 'That email already has an account. Sign in to it instead and carry your role over.' : error.message);
      const { error: passwordError } = await db.auth.updateUser({ password });
      if (!passwordError) await db.auth.updateUser({ data: { needs_password: false } });
      $('regPassword').value = '';
      await refresh();
      say(account.status === 'guest' ? 'Check your email and open the confirmation link on this device. Then return here to set your password and finish the account. Your seats stay with this browser meanwhile.' : 'Account created. Your existing seats came with you.');
      return;
    }
    const { data, error } = await db.auth.signUp({ email, password, options: { emailRedirectTo: redirectTo(), data: { username, display_name: display } } });
    if (error) throw Error(error.message);
    $('regPassword').value = '';
    if (data?.session) { try { await saveProfile(username, display); } catch (err) { say(err.message); } await refresh(); }
    else { showTab(false); say('Almost there: open the confirmation link we emailed you, then sign in. If the address already has an account, sign in or reset its password instead.'); }
  }); };

  $('resetForm').onsubmit = (e) => { e.preventDefault(); guarded(async () => {
    await db.auth.resetPasswordForEmail($('resetEmail').value.trim().toLowerCase(), { redirectTo: redirectTo() });
    // Same answer whether or not the address exists.
    showTab(false); say('If that email has an account, a reset link is on its way. Open it on this device.');
  }); };

  $('newPasswordForm').onsubmit = (e) => { e.preventDefault(); guarded(async () => {
    const { error } = await db.auth.updateUser({ password: $('newPassword').value });
    if (error) throw Error(error.message);
    $('newPassword').value = ''; account.recovering = false; await refresh(); say('Password updated.');
  }); };

  $('profileForm').onsubmit = (e) => { e.preventDefault(); guarded(async () => {
    const username = $('profileUsername').value.trim().toLowerCase();
    if (!USERNAME.test(username)) throw Error('Usernames use 3–20 letters, numbers or underscores.');
    if (!$('profilePasswordWrap').hidden) {
      const { error } = await db.auth.updateUser({ password: $('profilePassword').value, data: { needs_password: false } });
      if (error) throw Error(error.message);
      $('profilePassword').value = '';
    }
    await saveProfile(username, $('profileDisplay').value.trim());
    await refresh(); say('');
  }); };

  db.auth.onAuthStateChange((event) => {
    if (event === 'PASSWORD_RECOVERY') { account.recovering = true; refresh(); }
    else if (event === 'SIGNED_OUT' || event === 'USER_UPDATED') setTimeout(refresh, 0);
  });

  return {
    account, refresh,
    async saveDisplayName(display) { await saveProfile(account.profile.username, display); await refresh(); },
    async signOut() { await db.auth.signOut(); account.recovering = false; await refresh(); },
  };
}

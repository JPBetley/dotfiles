# Login-shell config shared by every Mac. Pulled in by the Managed line in the
# ~/.zprofile Stub; machine-local lines stay in the Stub.

# Homebrew, wherever it is installed. The Homebrew installer doesn't add this
# itself, and a shellenv line already in the Stub is harmless.
for brew in /opt/homebrew/bin/brew /usr/local/bin/brew; do
	[ -x "$brew" ] && { eval "$("$brew" shellenv)"; break; }
done
unset brew

# frozen_string_literal: true

# Run with `gitlab-rails runner` on a fresh install. Exits 0 only when an
# active administrator exists whose email is GITLAB_ROOT_EMAIL and whose
# password is GITLAB_ROOT_PASSWORD.
#
# GitLab creates the administrator from those variables in its production
# seed, which runs only while the database is empty. If the seed failed on
# the first start (for example GitLab rejected the password), a later start
# finds a database without an administrator; the seed is then run again
# here, and it fails again for the same reason rather than leaving GitLab
# without an administrator.
#
# Never prints the password or GitLab's error details, which can echo it.

password = ENV['GITLAB_ROOT_PASSWORD'].to_s
email = ENV['GITLAB_ROOT_EMAIL'].to_s.strip.downcase

if password.empty? || email.empty?
  warn '[appbox] GITLAB_ROOT_EMAIL and GITLAB_ROOT_PASSWORD must both be set'
  exit 1
end

unless User.admins.exists?
  puts '[appbox] GitLab has no administrator yet; running its administrator seed again'
  begin
    SeedFu.seed([Rails.root.join('db/fixtures/production').to_s], /admin/)
  rescue SystemExit, StandardError
    warn '[appbox] GitLab could not create the administrator account'
  end
end

admin = User.admins.find_by(email: email)

if admin&.active? && admin.valid_password?(password)
  puts "[appbox] Administrator account confirmed: #{admin.username}"
  exit 0
end

warn '[appbox] No active administrator signs in with the install email and password'
exit 1

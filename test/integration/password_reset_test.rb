require "test_helper"

class PasswordResetTest < SystemTest
  include ActiveJob::TestHelper

  def password_reset_link
    body = ActionMailer::Base.deliveries.last.parts[1].body.decoded.to_s
    link = %r{http://localhost(?::\d+)?/password([^";]*)}.match(body)
    link[0]
  end

  setup do
    @user = create(:user, handle: nil)
  end

  def forgot_password_with(email)
    visit sign_in_path

    click_link "Forgot password?"
    fill_in "Email address", with: email
    perform_enqueued_jobs do
      click_button "Reset password"

      assert page.has_content? "You will receive an email within the next few minutes."
    end
  end

  test "reset password form does not tell if a user exists" do
    forgot_password_with "someone@example.com"

    assert page.has_content? "instructions for changing your password"
  end

  test "resetting password without handle" do
    forgot_password_with @user.email

    visit password_reset_link
    expected_path = "/password/edit"

    assert_equal expected_path, page.current_path, "removes confirmation token from url"

    fill_in "Password", with: PasswordHelpers::SECURE_TEST_PASSWORD
    click_button "Save this password"

    assert_equal sign_in_path, page.current_path

    fill_in "Email or Username", with: @user.email
    fill_in "Password", with: PasswordHelpers::SECURE_TEST_PASSWORD
    click_button "Sign in"

    assert page.has_content? "Sign out"
  end

  test "resetting a password with a blank or short password" do
    forgot_password_with @user.email

    visit password_reset_link

    fill_in "Password", with: ""
    click_button "Save this password"

    assert page.has_content? "Your password could not be changed. Please try again."
    assert page.has_content? "Password can't be blank"
    assert page.has_content? "Reset password"

    # try again with short password
    fill_in "Password", with: "pass"
    click_button "Save this password"

    assert page.has_content? "Password is too short (minimum is 10 characters)"
    assert page.has_content? "Reset password"

    # try again with valid password
    fill_in "Password", with: PasswordHelpers::SECURE_TEST_PASSWORD
    click_button "Save this password"

    assert_equal sign_in_path, page.current_path
    assert @user.reload.authenticated? PasswordHelpers::SECURE_TEST_PASSWORD
  end

  test "resetting a password but waiting too long after token auth" do
    forgot_password_with @user.email

    visit password_reset_link

    fill_in "Password", with: PasswordHelpers::SECURE_TEST_PASSWORD

    travel 16.minutes do
      click_button "Save this password"

      assert page.has_content? "verification has expired. Please verify again."
    end
  end

  test "resetting a password when signed in" do
    visit sign_in_path

    fill_in "Email or Username", with: @user.email
    fill_in "Password", with: @user.password
    click_button "Sign in"

    visit edit_settings_path

    click_link "Reset password"

    fill_in "Email address", with: @user.email
    perform_enqueued_jobs { click_button "Reset password" }

    visit password_reset_link

    assert page.has_content?("Sign out")

    fill_in "Password", with: PasswordHelpers::SECURE_TEST_PASSWORD
    click_button "Save this password"

    assert_equal sign_in_path, page.current_path
    assert @user.reload.authenticated? PasswordHelpers::SECURE_TEST_PASSWORD

    assert_event Events::UserEvent::PASSWORD_CHANGED, {},
      @user.events.where(tag: Events::UserEvent::PASSWORD_CHANGED).sole
  end

  test "restting password when mfa is enabled" do
    @user.enable_totp!(ROTP::Base32.random_base32, :ui_only)
    forgot_password_with @user.email

    visit password_reset_link

    refute page.has_content?("Sign out")

    fill_in "otp", with: ROTP::TOTP.new(@user.totp_seed).now
    click_button "Authenticate"

    refute page.has_content?("Sign out")

    fill_in "Password", with: PasswordHelpers::SECURE_TEST_PASSWORD
    click_button "Save this password"

    assert_equal sign_in_path, page.current_path
    assert @user.reload.authenticated? PasswordHelpers::SECURE_TEST_PASSWORD
  end

  test "resetting a password when mfa is enabled but mfa session is expired" do
    @user.enable_totp!(ROTP::Base32.random_base32, :ui_and_gem_signin)
    forgot_password_with @user.email

    visit password_reset_link

    fill_in "otp", with: ROTP::TOTP.new(@user.totp_seed).now
    travel 16.minutes do
      click_button "Authenticate"

      assert page.has_content? "Your login page session has expired."
    end
  end

  test "resetting password when webauthn is enabled" do
    create_webauthn_credential

    forgot_password_with @user.email

    visit password_reset_link

    assert page.has_content? "Multi-factor authentication"
    assert page.has_content? "Security Device"
    assert_not_nil page.find(".js-webauthn-session--form")[:action]

    click_on "Authenticate with security device"

    fill_in "Password", with: PasswordHelpers::SECURE_TEST_PASSWORD
    click_button "Save this password"

    assert page.has_content?("Sign in")
    assert_equal sign_in_path, page.current_path
    assert @user.reload.authenticated? PasswordHelpers::SECURE_TEST_PASSWORD
  end

  test "resetting password when webauthn is enabled using recovery codes" do
    create_webauthn_credential

    forgot_password_with @user.email

    visit password_reset_link

    refute page.has_content? "Sign out"
    assert page.has_content? "Multi-factor authentication"
    assert page.has_content? "Security Device"
    assert page.has_content? "Recovery code"
    assert_not_nil page.find(".js-webauthn-session--form")[:action]

    fill_in "otp", with: @mfa_recovery_codes.first
    click_button "Authenticate"

    fill_in "Password", with: PasswordHelpers::SECURE_TEST_PASSWORD
    click_button "Save this password"

    assert page.has_content?("Sign in")
    assert_equal sign_in_path, page.current_path
    assert @user.reload.authenticated? PasswordHelpers::SECURE_TEST_PASSWORD
  end

  test "resetting password with pending email change" do
    visit sign_in_path

    email = @user.email
    new_email = "hijack@example.com"

    fill_in "Email or Username", with: email
    fill_in "Password", with: @user.password
    click_button "Sign in"

    visit edit_profile_path

    fill_in "user_handle", with: "username"
    fill_in "Email address", with: new_email
    fill_in "Password", with: @user.password
    perform_enqueued_jobs { click_button "Update" }

    assert_equal new_email, @user.reload.unconfirmed_email

    click_link "Sign out"

    forgot_password_with email

    assert_nil @user.reload.unconfirmed_email

    token = /edit\?token=(.+)$/.match(password_reset_link)[1]
    visit update_email_confirmations_path(token: token)

    assert @user.reload.authenticated? PasswordHelpers::SECURE_TEST_PASSWORD
    assert_equal email, @user.email
  end

  test "resetting password of soft-deleted user" do
    @user.update!(deleted_at: Time.zone.now, email: "deleted+#{@user.id}@rubygems.org")

    forgot_password_with @user.email

    assert_empty ActionMailer::Base.deliveries
    page.assert_text "instructions for changing your password"
  end

  teardown do
    @authenticator&.remove!
    Capybara.reset_sessions!
    Capybara.use_default_driver
  end
end

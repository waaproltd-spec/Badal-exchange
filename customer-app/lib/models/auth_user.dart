/// Locally-known identity of the signed-in customer.
///
/// The backend's login/register responses only ever return {id, role[,
/// name]} -- there is no GET /customer/profile endpoint. So `name` and
/// `phone` are captured from what the customer typed at login/register
/// time (or the `name` the login response echoes back) and persisted
/// locally, rather than invented or fetched from a nonexistent endpoint.
class AuthUser {
  const AuthUser({required this.phone, required this.name});

  final String phone;
  final String name;
}

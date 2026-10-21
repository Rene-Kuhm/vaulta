/// Host normalization shared by every writer of the `vault_hosts` index.
///
/// The index exists so AutofillService can answer "which items belong to this
/// app's host" with one query. That only works if every writer agrees on the
/// normalized form, so the rule lives in exactly one function.
library;

/// Normalizes [website] to the bare host used as the autofill index key.
///
/// Drops the scheme, the path, the query and a leading `www.`, lowercases the
/// result, and returns `null` when there is nothing usable. Ports are kept,
/// because `localhost:8080` and `localhost` are different services.
String? vaultHostOfWebsite(String? website) {
  final trimmed = website?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;

  var host = trimmed.toLowerCase();
  final schemeEnd = host.indexOf('://');
  if (schemeEnd >= 0) host = host.substring(schemeEnd + 3);

  final cut = host.indexOf(RegExp(r'[/?#]'));
  if (cut >= 0) host = host.substring(0, cut);

  if (host.startsWith('www.')) host = host.substring(4);
  if (host.startsWith('www.')) return vaultHostOfWebsite(host); // defensive
  return host.isEmpty ? null : host;
}

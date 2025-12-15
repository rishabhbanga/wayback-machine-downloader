require "openssl"

# Workaround for SSL cert CRL verification issue (OpenSSL 3.6.0 + Ruby 3.4)
store = OpenSSL::X509::Store.new.tap(&:set_default_paths)
OpenSSL::SSL::SSLContext::DEFAULT_PARAMS[:cert_store] = store

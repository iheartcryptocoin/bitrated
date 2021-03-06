{ create_multisig } = require '../../lib/bitcoin/index.coffee'
{ iferr, error_displayer, parse_query, navto, render } = require '../lib/util.coffee'
{ format_locals, build_tx_args } = require './lib/util.coffee'
{ handshake_reply } = require './lib/networking.coffee'
{ load_user } = require '../lib/user.coffee'
{ triple_sha256 } = require '../../lib/bitcoin/index.coffee'
Key = require '../../lib/bitcoin/key.coffee'
sign_message = require '../sign-message.coffee'
view = require './views/join.jade'

ACK_TIMEOUT = 30000 # 30 seconds

display_error = error_displayer $ '.content'

# Read and validate query params
{ alice, trent, terms, proof, channel } = parse_query()

try
  for key, val of { alice, trent, terms, proof, channel } when not val
    throw new Error "Missing argument: #{ key }"

  alice = Key.from_pubkey alice
  trent = Key.from_pubkey trent

  unless alice.verify_sig terms, proof
    throw new Error 'Invalid signature provided by other party'

catch err then return display_error err

# Render the view
render el = $ view format_locals {
  alice, trent, terms, proof
  bob: Key.random()
}

# Display arbitrator info on request
arb_info = el.find('.arbitrator-info')
arb_info.find('button').click ->
  trent = Key.from_pubkey el.find('.trent-pubkey').text()
  check_button = $(this).addClass('active').attr('disabled', true)
  pubkey_hash = triple_sha256 trent.pub
  load_user pubkey_hash, (err, user) ->
    check_button.removeClass('active').attr('disabled', false)
    return display_error err if err?
    if user?
      arb_info.addClass('loaded').find('.username').html "<a href='/u/#{user.username}'>#{user.username}</a>"
    else arb_info.addClass('not-found')

# Spinner helpers
button = el.find 'form button[type=submit]'
start_spinner = -> button.attr('disabled', true).addClass('active')
stop_spinner =  -> button.attr('disabled', false).removeClass('active')

# Make display_error stop the spinner in addition to showing the error
display_error = do (display_error) -> (err) ->
  stop_spinner?()
  display_error err

# Handle form submission
el.find('form').submit (e) ->
  e.preventDefault()

  do start_spinner

  # Parse user public/private key
  try bob = Key.from_string el.find('input[name=bob]').val()
  catch err
    el.find('input[name=bob]').focus()
    return display_error err

  { script } = create_multisig [ bob.pub, alice.pub, trent.pub ]

  # Sign message (with known private key, or with dialog asking user to do this
  # locally)
  sign_message bob, terms, iferr display_error, (sig) ->
    ack_timer = setTimeout (->
      display_error 'Handshake verification response timed out. The other party might have closed the page.'
    ), ACK_TIMEOUT
    handshake_reply channel, { pub: bob.pub, proof: sig, script }, (err) ->
      clearTimeout ack_timer
      return display_error err if err?
      navto 'tx.html', build_tx_args { bob, alice, trent, terms, proof, _is_new: true }, true

# Advanced options
el.find('a[href="#advanced"]').click (e) ->
  e.preventDefault()
  el.find('.keys-advanced').toggle 'slow'

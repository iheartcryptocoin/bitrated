{ BigInteger, Transaction, TransactionOut, Util, convert: { bytesToHex, hexToBytes } } = require 'bitcoinjs-lib'
{ parseValue, formatValue } = Util
{ iferr, error_displayer } = require '../../lib/util.coffee'
{ get_address, parse_address, parse_key_bytes, get_pub
  create_out_script, get_script_address
  ADDR_PUB, ADDR_PRIV, ADDR_P2SH } = require '../../../lib/bitcoin/index.coffee'
{ sign_tx, calc_total_in, sum_inputs, decode_raw_tx, verify_tx_sig } = require '../../../lib/bitcoin/tx.coffee'
{ tx_listen, load_unspent } = require './networking.coffee'

# Initialize the transaction builder interface
tx_builder = (el, { key, trent, multisig, script, channel }, cb) ->
  display_error = error_displayer el
  unspent = balance = null
  addresses = el.find('.addresses')

  get_fee = -> parseValue el.find('input[name=fees]').val()

  # Add address
  el.find('.add-address').click do (addr_tmpl=null) -> ->
    addr_tmpl ?= addresses.find('.address:eq(0)').clone()
      .find('input').val('').end()
      .find('.add-address').toggleClass('add-address del-address').end()
      .find('.icon-plus').toggleClass('icon-plus icon-minus').end()
    addresses.append addr_tmpl.clone()

  # Delete address
  el.on 'click', '.del-address', -> $(this).closest('.address').remove()

  # Address dropdown items
  el.on 'click', '[data-address]', ->
    $(this).closest('.address').find('input[name=address]').val $(this).data('address')

  # Pay remaining, minus fees
  el.on 'click', '.pay-remaining', ->
    val_el = $(this).closest('.address').find('[name=value]')
    spent = sum_value_inputs el.find('.address input[name=value]').not(val_el)
    remain = Math.max 0, balance - spent - get_fee()
    val_el.val formatValue remain
    do update_change

  # Pay %
  el.on 'click', '.pay-some', ->
    val_el = $(this).closest('.address').find('[name=value]')
    return unless percentage = prompt 'Enter the percentage to pay (between 0% and 100%)'
    percentage = +percentage.replace /\s|%/g, ''
    return display_error 'Invalid percentage amount' if isNaN percentage
    amount = balance/100*percentage
    val_el.val formatValue amount
    do update_change

  # Update balance
  el.find('.update-balance').click update_balance = ->
    refresh_icon = $(this).find('i').addClass 'icon-spin'
    load_unspent multisig, (err, _unspent) ->
      refresh_icon.removeClass 'icon-spin'
      return display_error err if err?
      unspent = _unspent
      balance = sum_inputs unspent
      $('.balance').text (formatValue balance)+' BTC'
  do update_balance
  
  cb_success = cb.bind null, null

  # Helper for displaying the transaction dialog with
  # all the common options
  show_dialog = (tx, initiator) ->
    try
      tx.total_in ?= calc_total_in tx, unspent
      tx_dialog { key, script, multisig, tx, el, initiator },
                iferr display_error, cb_success
    catch err then display_error err

  # Release button - open dialog for confirmation
  el.find('.release').click ->
    try show_dialog build_tx(), 'self'
    catch e then display_error e

  # Input raw transaction
  el.find('.input-rawtx').click ->
    input_rawtx_dialog iferr display_error, (tx) ->
      show_dialog tx, 'self'

  # Get raw transaction
  el.find('.show-rawtx').click ->
    try show_rawtx_dialog build_tx unspent, el
    catch e then display_error e

  # Auto-update the change amount
  el.on 'change keyup', '.address input[name=value], input[name=fees]', update_change = ->
    spent = sum_value_inputs el.find('.address input[name=value]')
    change = Math.max 0, balance - spent - get_fee()
    el.find('.change-amount').text (formatValue change) + ' BTC'

  # Add transaction request to list
  add_tx_request = do ($requests = $ '.tx-requests') -> (tx) ->
    # TODO validate tx
    # TODO validate signature
    txid = bytesToHex tx.getHash()
    $(document.createElement 'li')
      .text("#{ txid }")
      .click(show_dialog.bind null, tx, 'other')
      .appendTo($requests.find 'ul')
    $requests.addClass 'has-requests'

  # Subscribe to transaction requests
  tx_unlisten = tx_listen channel, add_tx_request

  # Build transaction with the given inputs and parse outputs from <form>
  build_tx = ->
    tx = new Transaction

    # Add inputs
    tx.addInput { hash }, index for { hash, index } in unspent
    tx.total_in = sum_inputs unspent
    
    # Read outputs from DOM
    el.find('.address').each ->
      $this = $ this
      amount = +parseValue $this.find('[name=value]').val()
      tx.addOutput new TransactionOut
        script: create_out_script $this.find('[name=address]').val()
        value: amount
    change = tx.total_in - (sum_inputs tx.outs) - get_fee()
    if change > 0
      tx.addOutput new TransactionOut
        script: create_out_script multisig
        value: change
    tx

  tx_unlisten

# Display the transaction dialog
tx_dialog = do (view=require '../views/dialogs/confirm-tx.jade') ->
  ({ key, tx, script, initiator, multisig }, cb) ->
    unless tx.ins.length
      return cb new Error 'No inputs provided'
    unless tx.outs.length
      return cb new Error 'No outputs provided'

    total_out = sum_inputs (value for { value } in tx.outs)
    if tx.total_in? and (total_out > tx.total_in)
      return cb new Error 'Insufficient funds. If the payment was sent recently,
                           it might not be confirmed yet.
                           You can refresh the balance to check for new payments.'

    dialog = $ view {
      outs: for { script: out_script, value } in tx.outs
        address: out_address = get_script_address out_script
        value: formatValue value
        is_change: out_address is multisig
      has_priv: key.priv?
      pub_address: get_address key.pub, ADDR_PUB
      total_in: formatValue tx.total_in
      fees: formatValue tx.total_in - total_out
      rawtx: bytesToHex tx.serialize()
      initiator
      final: initiator is 'other'
    }

    display_error = error_displayer dialog.find('.modal-body .errors')

    get_signed_tx = ->
      # Sign with the known private key
      if key.priv?
        sign_tx key.eckey, tx, script
      # Use user-provided private key
      else if priv_text = dialog.find(':visible[name=priv]').val()
        priv_ = parse_address priv_text, ADDR_PRIV
        throw new Error 'Invalid private key provided' unless (bytesToHex get_pub priv_) is (bytesToHex key.pub)
        sign_tx priv_, tx, script
      # Use user-provided signed transaction
      else if rawtx = dialog.find(':visible[name=signed-raw-tx]').val()
        try
          rawtx = JSON.parse(rawtx).hex if ~rawtx.indexOf '{'
          rawtx = hexToBytes rawtx
          signed_tx = decode_raw_tx rawtx
        catch e then throw new Error 'Invalid raw transaction format'
        throw new Error 'Invalid signature provided' unless verify_tx_sig key.pub, signed_tx, script
        signed_tx
      else
        throw new Error 'Please provide the private key or the signed transaction'

    dialog.find('.authorize .ok').click ->
      dialog
        .find('.authorize').hide().end()
        .find('.confirm').show().end()

    dialog.find('.confirm .ok').click ->
      try
        cb null, get_signed_tx()
        dialog.modal 'hide'
      catch err then display_error err

    dialog.on 'hidden', -> do dialog.remove
    dialog.modal()

show_rawtx_dialog = do (view = require '../views/dialogs/show-rawtx.jade') -> (tx) ->
  rawtx = bytesToHex tx.serialize()
  dialog = $ view { rawtx }
  dialog.on 'hidden', -> do dialog.remove
  dialog.modal()

input_rawtx_dialog = do (view = require '../views/dialogs/input-rawtx.jade') -> (cb) ->
  dialog = $ view()
  display_error = error_displayer dialog.find('.errors')

  dialog.find('form').on 'submit', (e) ->
    e.preventDefault()
    try
      cb null, decode_raw_tx hexToBytes dialog.find('[name=rawtx]').val()
      dialog.modal 'hide'
    catch e then display_error e

  dialog.on 'hidden', -> do dialog.remove
  dialog.modal()

sum_value_inputs = ($els) ->
  sum_inputs $els
    .filter(->!!@value)
    .map(-> +parseValue @value).get()

module.exports = tx_builder

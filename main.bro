
module CreditCardExposure;

export {
	redef enum Log::ID += { LOG };

	redef enum Notice::Type += { 
		Found
	};

	type Info: record {
		## When the SSN was seen.
		ts:   time    &log;
		## Unique ID for the connection.
		uid:  string  &log;
		## Connection details.
		id:   conn_id &log;
		## Credit card number that was discovered.
		cc:   string  &log &optional;
		## Data that was received when the credit card was discovered.
		data: string  &log;
	};
	
	## Logs are redacted by defaultIf you want to see the credit card numbers in 
	## the log, redef this value to T.  
	## Notices are automatically and unchangeably redacted.
	const redact_log = F &redef;

	## The character used for redaction to replace all numbers.
	const redaction_char = "X" &redef;

	## The number of bytes around the discovered credit card number that is used 
	## as a summary in notices.
	const summary_length = 200 &redef;

	const cc_regex = /^[3-9]{4}([ -\.]?\x00?[0-9]{4}){3}$/ &redef;

	const cc_separators = /\.(.*\.){3}/ | 
	                      /\-(.*\-){3}/ | 
	                      /[:blank:](.*[:blank:]){3}/ &redef;
}

const luhn_vector = vector(0,2,4,6,8,1,3,5,7,9);
function luhn_check(val: string): bool
	{
	local sum = 0;
	local odd = T;
	local parts = str_split(gsub(val, /[^0-9]/, ""), vector(1,2,3,4,5,6,7,8,9,10,11,12,13,14,15));
	for ( i in parts )
		{
		odd = !odd;
		local digit = to_count(parts[i]);
		sum += (odd ? digit : luhn_vector[digit]);
		}
	return sum % 10 == 0;
	}

event bro_init() &priority=5
	{
	Log::create_stream(CreditCardExposure::LOG, [$columns=Info]);
	}


function check_cards(c: connection, data: string): bool
	{
	local ccps = find_all(data, cc_regex);

	for ( ccp in ccps )
		{
		if ( cc_separators in ccp && luhn_check(ccp) )
			{
			# we've got a match
			local parts = split_all(data, cc_regex);
			local cc_match = "";
			local redacted_cc = "";
			for ( i in parts )
				{
				if ( i % 2 == 0 )
					{
					# Redact all matches and save one back for 
					# finding it's location.
					cc_match = parts[i];
					parts[i] = gsub(parts[i], /[0-9]/, redaction_char);
					redacted_cc = parts[i];
					}
				}

			local redacted_data = join_string_array("", parts);
			local cc_location = strstr(data, cc_match);

			local begin = 0;
			if ( cc_location > (summary_length/2) )
				begin = cc_location - (summary_length/2);
			
			local byte_count = summary_length;
			if ( begin + summary_length > |redacted_data| )
				byte_count = |redacted_data| - begin;

			local trimmed_data = sub_bytes(redacted_data, begin, byte_count);

			NOTICE([$note=Found,
			        $conn=c,
			        $msg=fmt("Redacted excerpt of disclosed credit card session: %s", trimmed_data),
			        $identity=cat(c$id$orig_h,c$id$resp_h)]);

			local log: Info = [$ts=network_time(), 
			                   $uid=c$uid, $id=c$id,
			                   $cc=(redact_log ? redacted_cc : cc_match),
			                   $data=(redact_log ? redacted_data : data)];

			Log::write(CreditCardExposure::LOG, log);
			return T;
			}
		}
	return F;
	}

event http_entity_data(c: connection, is_orig: bool, length: count, data: string)
	{
	if ( c$start_time > network_time()-10secs )
		check_cards(c, data);
	}

event mime_segment_data(c: connection, length: count, data: string)
	{
	if ( c$start_time > network_time()-10secs )
		check_cards(c, data);
	}

# This is used if the signature based technique is in use
function validate_credit_card_match(state: signature_state, data: string): bool
	{
	# TODO: Don't handle HTTP data this way.
	if ( /^GET/ in data )
		return F;

	return check_cards(state$conn, data);
	}
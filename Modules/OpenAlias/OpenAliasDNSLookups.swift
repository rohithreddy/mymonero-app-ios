//
//  HostedMonero_OpenAliasResolving.swift
//  MyMonero
//
//  Created by Paul Shapiro on 5/9/17.
//  Copyright © 2017 MyMonero. All rights reserved.
//

import Foundation
//
//
struct OpenAliasDNSLookups
{
	//
	// Types
	struct ResolvedAddressDescription
	{
		let recipient_address: String
		let recipient_name: String?
		let payment_id: MoneroPaymentID?
		let tx_description: String?
	}
	struct ValidResolvedAddressDescription
	{
		let recipient_address: MoneroAddress
		let recipient_name: String?
		let payment_id: MoneroPaymentID?
		let tx_description: String?
	}
	//
	// Interface
	static func moneroAddressInfo(
		fromOpenAliasAddress openAliasAddress: String,
		forCurrency currency: OpenAliasAddressCurrency,
		isReachable: Bool,
		fn: @escaping (
			_ err_str: String?,
			_ validResolvedAddressDescription: ValidResolvedAddressDescription?
		) -> Void
	) -> Operation? // can be canceled
	{
		if OpenAlias.containsPeriod_excludingAsXMRAddress_qualifyingAsPossibleOAAddress(openAliasAddress) == false {
			let err_str = NSLocalizedString("Not an OpenAlias address", comment: "")
			assert(false, "code fault") // not expecting this
			fn(err_str, nil)
			return nil
		}
		if isReachable == false {
			let err_str = String(
				format: NSLocalizedString("Couldn't look up %@… No Internet Connection Found", comment: ""),
				openAliasAddress				
			)
			fn(err_str, nil)
			return nil
		}
		let emailNormalized_address = openAliasAddress.replacingOccurrences(of: "@", with: ".")
		let operation = DNSLookups.shared.TXTRecords(
			forDomain: emailNormalized_address,
			{ (err_str, recordRows) in
				if err_str != nil {
					let returnable__err_str = String(
						format: NSLocalizedString("Couldn't look up %@… %@", comment: ""),
						openAliasAddress,
						err_str!
					)
					fn(returnable__err_str, nil)
					return
				}
				let recordRows_count = recordRows!.count
				if recordRows_count == 0 {
					fn(NSLocalizedString("No DNS records found during OA address lookup.", comment: ""), nil)
					return
				}
				var addressDescriptions: [ResolvedAddressDescription] = []
				for (_, recordRow) in recordRows!.enumerated() {
					let (err_str, parsedDescription) = self.new_parsedDescription(
						fromTXTRecordString: recordRow.recordText,
						forCurrency: currency
					)
					if err_str != nil {
						fn(err_str!, nil)
						return // bail
					}
					if parsedDescription == nil {
						continue // no OA info on recordRow - at least not for the requested currency - TODO? update this to return all available currencies?
					}
					if recordRow.DNSSEC_isFlagSet_statusAvailable {
						if recordRow.DNSSEC_isFlagSet_secure {
							assert(recordRow.DNSSEC_isFlagSet_insecure == false)
							DDLog.Done("OpenAlias", "DNSSEC validation successful")
						} else {
							let returnable__err_str = String(
								format: NSLocalizedString("DNSSEC validation failed for %@", comment: ""),
								openAliasAddress
							)
							fn(returnable__err_str, nil)
							return // bail
						}
					} else {
						DDLog.Warn("OpenAlias", "DNSSEC status not available")
					}
					//
					addressDescriptions.append(parsedDescription!)
				}
				//
				let addressDescriptions_count = addressDescriptions.count
				if addressDescriptions_count == 0 {
					let err_str = String(
						format: NSLocalizedString("No valid OpenAlias records with prefix %@ found for %@", comment: ""),
						currency.txtRecordPrefixTokenForCurrency,
						openAliasAddress
					)
					fn(err_str, nil)
					return
				}
				if addressDescriptions_count > 1 {
					let err_str = String(
						format: NSLocalizedString("Multiple %@ target addresses found for domain %@", comment: ""),
						currency.txtRecordPrefixTokenForCurrency,
						openAliasAddress
					)
					fn(err_str, nil)
					return
				}
				//
				let resolvedAddressDescription = addressDescriptions.first!
//				DDLog.Info("OpenAlias", "resolvedAddressDescription: \(resolvedAddressDescription)")
				//
				// now verify address is decodable for currency
				assert(currency == .monero) // only one supported at the moment
				MyMoneroCore.shared.DecodeAddress(resolvedAddressDescription.recipient_address)
				{ (err_str, decodedAddressComponents) in
					if let _ = err_str {
						fn(NSLocalizedString("Domain's TXT records had OpenAlias prefix but not a valid Monero address.", comment: ""), nil)
						return
					}
					let validResolvedDescription = ValidResolvedAddressDescription(
						recipient_address: resolvedAddressDescription.recipient_address,
						recipient_name: resolvedAddressDescription.recipient_name,
						payment_id: resolvedAddressDescription.payment_id,
						tx_description: resolvedAddressDescription.tx_description
					)
					fn(nil, validResolvedDescription)
				}
			}
		)
		return operation
	}
	
	enum OpenAliasAddressCurrency: String
	{
		case monero = "xmr"
		case bitcoin = "btc"
		//
		var txtRecordPrefixTokenForCurrency: String {
			return self.rawValue
		}
	}
	static func hasValid(
		tokenInTXTRecordForCurrency currency: OpenAliasAddressCurrency,
		inRecord record: String
	) -> Bool
	{
		let oaPrefix = OpenAlias.txtRecord_oaPrefix
		let tokenForCurrency = currency.txtRecordPrefixTokenForCurrency
		let range = NSMakeRange(0, oaPrefix.characters.count + 1 + tokenForCurrency.characters.count + 1) // trailing +1 for space - extra validation
		let record_prefixString = (record as NSString).substring(with: range)
		let expected_prefixString = "\(oaPrefix):\(tokenForCurrency) "
		if record_prefixString != expected_prefixString {
			return false
		}
		return true
	}
	fileprivate static func new_parsedDescription(
		fromTXTRecordString recordString: String,
		forCurrency currency: OpenAliasAddressCurrency
	) -> (
		err_str: String?,
		description: ResolvedAddressDescription?
	)
	{
		let hasValidTokenForCurrency = self.hasValid(
			tokenInTXTRecordForCurrency: currency,
			inRecord: recordString
		)
		if hasValidTokenForCurrency == false { // do not treat as an error - probably is another currency like btc or some other TXT record
			return (err_str:nil, description: nil)
		}
		func parsed_paramValueWithName(_ valueName: String) -> String?
		{
			let valueName_length = valueName.characters.count
			let record_NSString = recordString as NSString
			let record_length = record_NSString.length
			let rangeOfValueNameKeyDeclaration = record_NSString.range(of: "\(valueName)=")
			if rangeOfValueNameKeyDeclaration.location == NSNotFound { // Record does not contain param
				DDLog.Warn("OpenAlias", "\(valueName) not found in OA record.")
				return nil
			}
			let nextDelimiter_searchRange_location = rangeOfValueNameKeyDeclaration.location + valueName_length + 1
			let nextDelimiter_searchRange = NSMakeRange(nextDelimiter_searchRange_location, record_length - nextDelimiter_searchRange_location)
			let rangeOfNextDelimiter = record_NSString.range(of: ";", options: [], range: nextDelimiter_searchRange)
			let posOfNextDelimiter = rangeOfNextDelimiter.location
			let pos2 = posOfNextDelimiter == NSNotFound ? record_NSString.length : posOfNextDelimiter // cause we may be at end
			let parsedValue_range = NSMakeRange(
				nextDelimiter_searchRange_location,
				pos2 - nextDelimiter_searchRange_location
			)
			let parsedValue = record_NSString.substring(with: parsedValue_range)
			//
			return parsedValue
		}
		let recipient_address = parsed_paramValueWithName("recipient_address")
		if recipient_address == nil || recipient_address == "" {
			return (err_str: NSLocalizedString("No recipient_address found", comment: ""), description: nil)
		}
		let recipient_name = parsed_paramValueWithName("recipient_name")
		let tx_payment_id = parsed_paramValueWithName("tx_payment_id")
		let tx_description = parsed_paramValueWithName("tx_description")
		let description = ResolvedAddressDescription(
			recipient_address: recipient_address!,
			recipient_name: recipient_name,
			payment_id: tx_payment_id,
			tx_description: tx_description
		)
		//
		return (err_str: nil, description: description)
	}
}
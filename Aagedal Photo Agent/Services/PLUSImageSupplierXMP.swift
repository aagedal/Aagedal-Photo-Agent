import Foundation
import SwiftExif

/// PLUS defines `plus:ImageSupplier` as an ordered `rdf:Seq`. SwiftExif retains a sequence form
/// when it parsed one, but version 1.9.10 does not yet list this property among its built-in Seq
/// properties, so a newly-created structured array otherwise serializes as `rdf:Bag`.
///
/// Seed the parsed container-form metadata before setting the real value. All existing PLUS
/// properties are copied through, so this workaround changes only the ImageSupplier container
/// form and can be removed once the dependency's property table includes it.
nonisolated enum PLUSImageSupplierXMP {
    static func enforceSequenceForm(in xmp: inout XMPData) {
        guard var seeded = sequenceSeed else { return }
        for (property, value) in xmp.properties(in: XMPNamespace.plus) {
            seeded.setValue(value, namespace: XMPNamespace.plus, property: property)
        }
        xmp.replaceAll(namespace: XMPNamespace.plus, from: seeded)
    }

    private static let sequenceSeed: XMPData? = {
        let xml = """
        <?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:plus="http://ns.useplus.org/ldf/xmp/1.0/">
           <plus:ImageSupplier>
            <rdf:Seq>
             <rdf:li rdf:parseType="Resource" plus:ImageSupplierID="sequence-form-seed"/>
            </rdf:Seq>
           </plus:ImageSupplier>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        return try? XMPReader.readFromXML(Data(xml.utf8))
    }()
}

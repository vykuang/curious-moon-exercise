DB=enceladus

BUILD=${CURDIR}/build.sql
SCRIPTS=${CURDIR}/scripts

CSV='${CURDIR}/data/master_plan.csv'
INMS_CSV='${CURDIR}/data/inms.csv'
CDA_CSV='${CURDIR}/data/cda.csv'
JPL_FLYBYS_CSV='${CURDIR}/data/jpl_flybys.csv'
CHEM_DATA_CSV='${CURDIR}/data/chem_data.csv'

all: import normalize
    psql -U postgres -d enceladus -f ${BUILD}

import:
    

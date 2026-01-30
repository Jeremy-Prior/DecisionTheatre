import { useMemo } from 'react';
import { Box } from '@chakra-ui/react';
import { motion, AnimatePresence } from 'framer-motion';
import ViewPane from './ViewPane';
import type { ComparisonState } from '../types';

type LayoutMode = 'single' | 'quad';

interface ContentAreaProps {
  mode: LayoutMode;
  comparison: ComparisonState;
}

// Default comparisons for the 4 quad panes
const QUAD_COMPARISONS: ComparisonState[] = [
  { leftScenario: 'past', rightScenario: 'present', attribute: '' },
  { leftScenario: 'present', rightScenario: 'future', attribute: '' },
  { leftScenario: 'past', rightScenario: 'future', attribute: '' },
  { leftScenario: 'past', rightScenario: 'present', attribute: '' },
];

const paneVariants = {
  hidden: { opacity: 0, scale: 0.92 },
  visible: (i: number) => ({
    opacity: 1,
    scale: 1,
    transition: {
      delay: i * 0.1,
      duration: 0.5,
      ease: [0.16, 1, 0.3, 1],
    },
  }),
  exit: (i: number) => ({
    opacity: 0,
    scale: 0.92,
    transition: {
      delay: (3 - i) * 0.06,
      duration: 0.3,
      ease: [0.4, 0, 1, 1],
    },
  }),
};

function ContentArea({ mode, comparison }: ContentAreaProps) {
  const isQuad = mode === 'quad';

  // In quad mode, first pane uses the shared comparison, rest use defaults
  const comparisons = useMemo(() => {
    if (!isQuad) return [comparison];
    return [comparison, QUAD_COMPARISONS[1], QUAD_COMPARISONS[2], QUAD_COMPARISONS[3]];
  }, [isQuad, comparison]);

  return (
    <Box
      position="relative"
      w="100%"
      h="100%"
      display="grid"
      gridTemplateColumns={isQuad ? '1fr 1fr' : '1fr'}
      gridTemplateRows={isQuad ? '1fr 1fr' : '1fr'}
      gap={isQuad ? '2px' : 0}
      bg={isQuad ? 'gray.700' : 'transparent'}
      sx={{
        transition: 'grid-template-columns 0.6s cubic-bezier(0.16, 1, 0.3, 1), grid-template-rows 0.6s cubic-bezier(0.16, 1, 0.3, 1), gap 0.6s cubic-bezier(0.16, 1, 0.3, 1)',
      }}
    >
      {/* Pane 0 is always rendered */}
      <Box
        position="relative"
        overflow="hidden"
        gridColumn={isQuad ? 'auto' : '1 / -1'}
        gridRow={isQuad ? 'auto' : '1 / -1'}
      >
        <ViewPane comparison={comparisons[0]} compact={isQuad} />
      </Box>

      {/* Panes 1-3 only in quad mode */}
      <AnimatePresence>
        {isQuad &&
          [1, 2, 3].map((i) => (
            <motion.div
              key={`pane-${i}`}
              custom={i}
              variants={paneVariants}
              initial="hidden"
              animate="visible"
              exit="exit"
              style={{ position: 'relative', overflow: 'hidden' }}
            >
              <ViewPane comparison={comparisons[i]} compact />
            </motion.div>
          ))}
      </AnimatePresence>
    </Box>
  );
}

export default ContentArea;
